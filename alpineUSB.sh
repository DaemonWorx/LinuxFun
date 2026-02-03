#!/usr/bin/env bash
# alpine-usb-persistent-universal.sh
# Universal (host-agnostic) Alpine USB installer: diskless + LBU persistence + XFCE
# Builds a persistent Alpine USB from ANY x86-64 Linux host using an Alpine minirootfs chroot.
set -euo pipefail

# ---------- User options ----------
DEVICE=""                 # REQUIRED: e.g. /dev/sdb  (WILL BE ERASED)
HOSTNAME="${HOSTNAME:-alpine-usb}"
USERNAME="${USERNAME:-alpine}"
TZ="${TZ:-America/New_York}"
KEYMAP="${KEYMAP:-us}"
# You may override ISO URL if Alpine updates: pass --iso-url "https://.../alpine-standard-<ver>-x86_64.iso"
ALPINE_ISO_URL="${ALPINE_ISO_URL:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-standard-3.20.3-x86_64.iso}"
MINIROOT_URL="${MINIROOT_URL:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/alpine-minirootfs-3.20.3-x86_64.tar.gz}"

TMP_BASE="/tmp/universal-installer"
ALP_TMP="${TMP_BASE}/alpine"
ROOT="${ALP_TMP}/rootfs"

# ---------- Helper: require root ----------
if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2;;
    --hostname) HOSTNAME="$2"; shift 2;;
    --user) USERNAME="$2"; shift 2;;
    --tz) TZ="$2"; shift 2;;
    --keymap) KEYMAP="$2"; shift 2;;
    --iso-url) ALPINE_ISO_URL="$2"; shift 2;;
    --miniroot-url) MINIROOT_URL="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

[[ -b "${DEVICE:-}" ]] || { echo "ERROR: --device must be a block device (e.g., /dev/sdb)"; exit 2; }
echo ">>> WARNING: This will ERASE ${DEVICE}"
read -rp "Type IUNDERSTAND to continue: " ACK
[[ "$ACK" == "IUNDERSTAND" ]] || { echo "Aborted."; exit 3; }

# ---------- Host prerequisites (auto-install) ----------
need() { command -v "$1" >/dev/null 2>&1; }
pm_install() {
  if need apt-get; then apt-get update && apt-get install -y "$@"
  elif need dnf; then dnf install -y "$@"
  elif need yum; then yum install -y "$@"
  elif need zypper; then zypper --non-interactive install "$@"
  elif need pacman; then pacman -Sy --noconfirm --needed "$@"
  elif need apk; then apk add --no-cache "$@"
  else echo "No supported package manager found. Install ${*} manually."; exit 4
  fi
}

for c in curl tar lsblk blkid wipefs partprobe sfdisk mkfs.vfat mkfs.f2fs; do
  need "$c" || pm_install curl tar util-linux dosfstools f2fs-tools
done

# ---------- Prepare Alpine minirootfs chroot ----------
mkdir -p "$ROOT"
cd "$ALP_TMP"
echo ">>> Downloading Alpine minirootfs..."
curl -L --fail -o minirootfs.tar.gz "$MINIROOT_URL"
echo ">>> Extracting minirootfs..."
tar -xpf minirootfs.tar.gz -C "$ROOT"

# Bind mounts + DNS
for d in dev proc sys run; do mount --rbind "/$d" "${ROOT}/$d"; mount --make-rslave "${ROOT}/$d"; done
cp -f /etc/resolv.conf "${ROOT}/etc/resolv.conf"

# ---------- Script to run inside Alpine chroot ----------
cat > "${ROOT}/root/in-chroot.sh" <<'ALP_INNER'
#!/bin/sh
set -eu

DEVICE="${DEVICE:?missing}"
HOSTNAME="${HOSTNAME:?missing}"
USERNAME="${USERNAME:?missing}"
TZ="${TZ:?missing}"
KEYMAP="${KEYMAP:?missing}"
ALPINE_ISO_URL="${ALPINE_ISO_URL:?missing}"

echo ">>> Updating apk, installing essentials..."
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main"      > /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/community" >> /etc/apk/repositories
apk update
apk add --no-cache alpine-conf lbu e2fsprogs f2fs-tools dosfstools util-linux tzdata curl ca-certificates \
                       grub-bios grub-efi dbus lightdm-gtk-greeter

# -------- Partition target: p1 FAT32 (trueroot) + p2 F2FS (/home) --------
echo ">>> Partitioning ${DEVICE}..."
swapoff -a || true
umount -R /mnt 2>/dev/null || true
for p in $(lsblk -ln -o NAME "$DEVICE" | tail -n +2); do umount -R "/dev/$p" 2>/dev/null || true; done
wipefs -a "$DEVICE" || true
# 1GiB FAT32 for trueroot/cache, rest F2FS for /home
sfdisk "$DEVICE" <<'PART'
label: dos
,1G,c,*
,,83
PART
partprobe "$DEVICE"; sleep 2
P1="${DEVICE}1"; P2="${DEVICE}2"

mkfs.vfat -F32 -n ALPINE_TRUEROOT "$P1"
mkfs.f2fs -f -l ALPINE_HOME "$P2"

mkdir -p /mnt/trueroot /mnt/home
mount "$P1" /mnt/trueroot
mount "$P2" /mnt/home
mkdir -p /mnt/trueroot/cache

# -------- Make it bootable using setup-bootable (from ISO) --------
apk add --no-cache syslinux # fallback if grub fails
echo ">>> Fetching Alpine Standard ISO (for setup-bootable)..."
mkdir -p /tmp/iso
curl -L --fail -o /tmp/iso/alpine.iso "$ALPINE_ISO_URL"
mkdir -p /mnt/iso
mount -o loop /tmp/iso/alpine.iso /mnt/iso
# Try GRUB (UEFI+BIOS); fallback to syslinux BIOS if GRUB fails
if ! setup-bootable -m /mnt/iso -u /mnt/trueroot -t grub; then
  echo "setup-bootable (grub) failed; falling back to syslinux (BIOS-only)..."
  setup-bootable -m /mnt/iso -u /mnt/trueroot -t syslinux
fi
umount /mnt/iso || true

# -------- Configure diskless persistence (LBU) & runtime mounts --------
echo ">>> Configuring LBU persistence and fstab..."
UUID_P1=$(blkid -s UUID -o value "$P1")
UUID_P2=$(blkid -s UUID -o value "$P2")
# Ensure these are present on the *running* system so trueroot/home mount each boot:
grep -q "/media/trueroot" /etc/fstab 2>/dev/null || echo "UUID=$UUID_P1  /media/trueroot  vfat  defaults,noatime  0  0" >> /etc/fstab
grep -q " /home "        /etc/fstab 2>/dev/null || echo "UUID=$UUID_P2  /home           f2fs  defaults,noatime  0  0" >> /etc/fstab
mkdir -p /media/trueroot
mount -t vfat -o defaults,noatime "/dev/disk/by-uuid/$UUID_P1" /media/trueroot || true
mount -t f2fs -o defaults,noatime "/dev/disk/by-uuid/$UUID_P2" /home || true
setup-lbu <<EOF
trueroot
EOF
setup-apkcache <<EOF
/media/trueroot/cache
EOF

# -------- Base runtime settings --------
setup-keymap "$KEYMAP"
setup-timezone -z "$TZ"
echo "$HOSTNAME" > /etc/hostname
# Minimal DHCP for first NIC:
IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' || true)"
if [ -n "$IFACE" ]; then
cat > /etc/network/interfaces <<NIF
auto lo
iface lo inet loopback
auto $IFACE
iface $IFACE inet dhcp
NIF
  rc-update add networking boot || true
fi

# Users
echo "root:alpineusb" | chpasswd
adduser -D -G wheel -s /bin/ash "$USERNAME" || true
echo "$USERNAME:alpineusb" | chpasswd

# -------- Install XFCE using Alpine's helper --------
echo "xfce" | setup-desktop

# Persist changes (write apkovl to /media/trueroot)
lbu commit

umount -R /mnt/trueroot || true
umount -R /mnt/home || true
sync
echo ">>> Alpine persistent USB build completed."
ALP_INNER
chmod +x "${ROOT}/root/in-chroot.sh"

# ---------- Pass env + run inside Alpine ----------
env -i DEVICE="$DEVICE" HOSTNAME="$HOSTNAME" USERNAME="$USERNAME" TZ="$TZ" KEYMAP="$KEYMAP" \
      ALPINE_ISO_URL="$ALPINE_ISO_URL" \
  chroot "$ROOT" /bin/sh /root/in-chroot.sh

# ---------- Teardown ----------
for d in dev proc sys run; do umount -R "${ROOT}/$d" || true; done
echo "DONE. You can now boot from ${DEVICE} (Alpine diskless + LBU persistence + XFCE)."