#!/usr/bin/env bash
# arch-usb-install-universal.sh
# Universal (host-agnostic) Arch USB installer using an Arch bootstrap chroot.
# Result: Arch on USB (Btrfs @/@home), XFCE + LightDM, GRUB (UEFI+BIOS).
# Host: any x86-64 Linux with sudo + internet.
set -euo pipefail

# ---------- User options ----------
DEVICE=""                 # REQUIRED: e.g. /dev/sdb  (WILL BE ERASED)
HOSTNAME="${HOSTNAME:-arch-usb}"
USERNAME="${USERNAME:-archuser}"
TZ="${TZ:-America/New_York}"
LOCALE="${LOCALE:-en_US.UTF-8}"

# Use a disk-backed workspace (avoid /tmp tmpfs)
TMP_BASE="/var/lib/universal-installer"
ARCH_TMP="${TMP_BASE}/arch"
ARCH_BOOTSTRAP_URL="${ARCH_BOOTSTRAP_URL:-https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst}"

# ---------- Helper: require root ----------
if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

# ---------- Parse args ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)   DEVICE="$2"; shift 2;;
    --hostname) HOSTNAME="$2"; shift 2;;
    --user)     USERNAME="$2"; shift 2;;
    --tz)       TZ="$2"; shift 2;;
    --locale)   LOCALE="$2"; shift 2;;
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
  if   need apt-get; then apt-get update && apt-get install -y "$@"
  elif need dnf;     then dnf install -y "$@"
  elif need yum;     then yum install -y "$@"
  elif need zypper;  then zypper --non-interactive install "$@"
  elif need pacman;  then pacman -Sy --noconfirm --needed "$@"
  elif need apk;     then apk add --no-cache "$@"
  else echo "No supported package manager found. Install ${*} manually."; exit 4; fi
}
for c in curl tar zstd lsblk blkid wipefs partprobe sgdisk mkfs.vfat mkfs.btrfs; do
  if ! need "$c"; then
    pm_install curl tar zstd util-linux gptfdisk dosfstools btrfs-progs e2fsprogs
    break
  fi
done

# Ensure workspace
mkdir -p "$ARCH_TMP"
cd "$ARCH_TMP"

# ---------- 1) Partition + format on HOST ----------
echo ">>> Partitioning ${DEVICE} (GPT: BIOS+ESP+Btrfs)..."
swapoff -a || true
umount -R /mnt 2>/dev/null || true
for p in $(lsblk -ln -o NAME "$DEVICE" | tail -n +2); do umount -R "/dev/$p" 2>/dev/null || true; done
wipefs -a "$DEVICE" || true

sgdisk -Z "$DEVICE"
sgdisk -o \
  -n 1:0:+1MiB   -t 1:EF02 \
  -n 2:0:+512MiB -t 2:EF00 \
  -n 3:0:0       -t 3:8304 "$DEVICE"
partprobe "$DEVICE"; sleep 2; udevadm settle

ESP="${DEVICE}2"
ROOTP="${DEVICE}3"
mkfs.vfat -F32 "$ESP"
mkfs.btrfs -f "$ROOTP"

# Create Btrfs subvolumes and mount target into the future chroot's /mnt
ROOT="${ARCH_TMP}/root.x86_64"
mkdir -p "${ROOT}/mnt"
mount "$ROOTP" "${ROOT}/mnt"
btrfs subvolume create "${ROOT}/mnt/@"
btrfs subvolume create "${ROOT}/mnt/@home"
umount "${ROOT}/mnt"

# Remount with subvols
mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@ "$ROOTP" "${ROOT}/mnt"
mkdir -p "${ROOT}/mnt/boot" "${ROOT}/mnt/home"
mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@home "$ROOTP" "${ROOT}/mnt/home"
mount "$ESP" "${ROOT}/mnt/boot"

# ---------- 2) Bootstrap Arch chroot (minimal) ----------
echo ">>> Downloading Arch bootstrap..."
curl -L --fail -o arch-bootstrap.tar.zst "$ARCH_BOOTSTRAP_URL"
echo ">>> Extracting bootstrap..."
tar --zstd -xpf arch-bootstrap.tar.zst

# Make '/' a real mountpoint inside the chroot (critical for pacman)
ROOT="${ARCH_TMP}/root.x86_64"
mount --bind "$ROOT" "$ROOT"
mount --make-private "$ROOT"

# Bind mounts + DNS
for d in dev proc sys run; do
  mount --rbind "/$d" "${ROOT}/$d"
  mount --make-rslave "${ROOT}/$d"
done
cp -f /etc/resolv.conf "${ROOT}/etc/resolv.conf"

# Bind host pacman cache (prevents chroot space issues)
mkdir -p /var/cache/pacman/pkg
mkdir -p "${ROOT}/var/cache/pacman/pkg"
mount --bind /var/cache/pacman/pkg "${ROOT}/var/cache/pacman/pkg"

# ---------- 3) Minimal tooling INSIDE chroot, pacstrap to USB ----------
cat > "${ROOT}/root/in-chroot.sh" <<'ARCH_INNER'
#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="${HOSTNAME:?missing}"
USERNAME="${USERNAME:?missing}"
TZ="${TZ:?missing}"
LOCALE="${LOCALE:?missing}"

# Minimal init for pacman
pacman-key --init
pacman-key --populate archlinux
printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n' > /etc/pacman.d/mirrorlist

# ONLY the installer scripts; do NOT install desktop here
pacman -Sy --noconfirm arch-install-scripts

# Install Arch onto the ALREADY-MOUNTED target at /mnt
pacstrap /mnt base linux linux-firmware networkmanager sudo vim btrfs-progs intel-ucode amd-ucode \
         xfce4 xfce4-goodies lightdm lightdm-gtk-greeter firefox grub efibootmgr

# Generate fstab + tune mount options
genfstab -U /mnt > /mnt/etc/fstab
sed -i 's|\(\s/\s\)btrfs\s\w\+|\1btrfs rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@|' /mnt/etc/fstab
sed -i 's|\(\s/home\s\)btrfs\s\w\+|\1btrfs rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@home|' /mnt/etc/fstab

# Post-config inside installed system
arch-chroot /mnt /bin/bash <<EOS
set -euo pipefail

ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime
hwclock --systohc
sed -i "s/^#${LOCALE}/${LOCALE}/" / /etc/locale.gen || true
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf

echo "${HOSTNAME}" > /etc/hostname
cat > /etc/hosts <<HST
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HST

echo "root:archusb" | chpasswd
useradd -m -G wheel -s /bin/bash ${USERNAME}
echo "${USERNAME}:archusb" | chpasswd
sed -i 's/^# %wheel/%wheel/' /etc/sudoers

# Portable initramfs
sed -i 's/^HOOKS=.*/HOOKS=(base udev keyboard keymap block autodetect modconf filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader (UEFI + BIOS)
grub-install --target=i386-pc --recheck /dev/$(lsblk -no pkname /mnt | head -n1) || true
grub-install --target=x86_64-efi --efi-directory=/boot --removable --recheck || true
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager
systemctl enable lightdm

# Light write-wear
sed -i 's/ defaults/ defaults,noatime/' /etc/fstab
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/10-volatile.conf <<J
[Journal]
Storage=volatile
SystemMaxUse=16M
RuntimeMaxUse=32M
J
EOS

sync
ARCH_INNER
chmod +x "${ROOT}/root/in-chroot.sh"

# Pass env + run inside chroot
env -i HOSTNAME="$HOSTNAME" USERNAME="$USERNAME" TZ="$TZ" LOCALE="$LOCALE" \
  chroot "$ROOT" /bin/bash /root/in-chroot.sh

# ---------- 4) Teardown + unmount target ----------
umount -R "${ROOT}/var/cache/pacman/pkg" || true
for d in dev proc sys run; do umount -R "${ROOT}/$d" || true; done
umount -R "${ROOT}" || true

umount -R "${ROOT}/mnt" 2>/dev/null || true
echo "DONE. You can now boot from ${DEVICE} (Arch + XFCE, Btrfs)."