#!/usr/bin/env bash
# arch-usb-install-universal.sh
# Universal (host-agnostic) Arch USB installer using a bootstrap Arch chroot
# Result: Full Arch on USB, Btrfs (@ and @home), XFCE + LightDM, GRUB (UEFI+BIOS)
# Requirements: x86-64 host, sudo, internet
set -euo pipefail

# ---------- User options ----------
DEVICE=""                 # REQUIRED: e.g. /dev/sdb  (WILL BE ERASED)
HOSTNAME="${HOSTNAME:-arch-usb}"
USERNAME="${USERNAME:-archuser}"
TZ="${TZ:-America/New_York}"
LOCALE="${LOCALE:-en_US.UTF-8}"

TMP_BASE="/tmp/universal-installer"
ARCH_TMP="${TMP_BASE}/arch"
ARCH_BOOTSTRAP_URL="${ARCH_BOOTSTRAP_URL:-https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst}"

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
    --locale) LOCALE="$2"; shift 2;;
    *) echo "Unknown arg: $1"; exit 1;;
  case_esac
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

for c in curl tar lsblk blkid wipefs partprobe sgdisk mkfs.vfat mkfs.btrfs zstd; do
  need "$c" || pm_install \
    curl tar util-linux gptfdisk dosfstools btrfs-progs e2fsprogs zstd
done

# ---------- Prepare bootstrap chroot ----------
mkdir -p "$ARCH_TMP"
cd "$ARCH_TMP"
echo ">>> Downloading Arch bootstrap..."
curl -L --fail -o arch-bootstrap.tar.zst "$ARCH_BOOTSTRAP_URL"
echo ">>> Extracting bootstrap..."
tar --zstd -xpf arch-bootstrap.tar.zst

ROOT="${ARCH_TMP}/root.x86_64"

# Bind mounts + DNS
for d in dev proc sys run; do mount --rbind "/$d" "${ROOT}/$d"; mount --make-rslave "${ROOT}/$d"; done
cp -f /etc/resolv.conf "${ROOT}/etc/resolv.conf"

# ---------- Create script to run inside Arch chroot ----------
cat > "${ROOT}/root/in-chroot.sh" <<'ARCH_INNER'
#!/usr/bin/env bash
set -euo pipefail

DEVICE="${DEVICE:?missing}"
HOSTNAME="${HOSTNAME:?missing}"
USERNAME="${USERNAME:?missing}"
TZ="${TZ:?missing}"
LOCALE="${LOCALE:?missing}"

echo ">>> Initializing pacman keys and minimal tooling..."
pacman-key --init
pacman-key --populate archlinux
# Minimal mirrorlist (you may replace with reflector later)
printf 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch\n' > /etc/pacman.d/mirrorlist
pacman -Sy --noconfirm arch-install-scripts gptfdisk dosfstools util-linux btrfs-progs e2fsprogs grub efibootmgr \
                       networkmanager sudo vim xfce4 xfce4-goodies lightdm lightdm-gtk-greeter firefox

# -------- Partition target (GPT: BIOS+ESP+Btrfs) --------
echo ">>> Partitioning ${DEVICE}..."
swapoff -a || true
umount -R /mnt 2>/dev/null || true
for p in $(lsblk -ln -o NAME "$DEVICE" | tail -n +2); do umount -R "/dev/$p" 2>/dev/null || true; done
wipefs -a "$DEVICE" || true
sgdisk -Z "$DEVICE"
sgdisk -o \
  -n 1:0:+1MiB   -t 1:EF02 \
  -n 2:0:+512MiB -t 2:EF00 \
  -n 3:0:0       -t 3:8304 "$DEVICE"
partprobe "$DEVICE"; udevadm settle; sleep 2
ESP="${DEVICE}2"; ROOTP="${DEVICE}3"

mkfs.vfat -F32 "$ESP"
mkfs.btrfs -f "$ROOTP"

# -------- Btrfs subvols and mounts --------
mount "$ROOTP" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
umount /mnt
mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@ "$ROOTP" /mnt
mkdir -p /mnt/{boot,home}
mount -o noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@home "$ROOTP" /mnt/home
mount "$ESP" /mnt/boot

# -------- Install Arch to USB --------
pacstrap /mnt base linux linux-firmware networkmanager sudo vim btrfs-progs intel-ucode amd-ucode \
         xfce4 xfce4-goodies lightdm lightdm-gtk-greeter firefox

genfstab -U /mnt > /mnt/etc/fstab
sed -i 's|\(\s/\s\)btrfs\s\w\+|\1btrfs rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@|' /mnt/etc/fstab
sed -i 's|\(\s/home\s\)btrfs\s\w\+|\1btrfs rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=@home|' /mnt/etc/fstab

# -------- Post-config inside installed system --------
arch-chroot /mnt /bin/bash <<EOS
set -euo pipefail
ln -sf /usr/share/zoneinfo/${TZ} /etc/localtime
hwclock --systohc
sed -i "s/^#${LOCALE}/${LOCALE}/" /etc/locale.gen || true
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
pacman -S --noconfirm grub efibootmgr
grub-install --target=i386-pc --recheck ${DEVICE}
grub-install --target=x86_64-efi --efi-directory=/boot --removable --recheck
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

umount -R /mnt
sync
echo ">>> Arch USB build completed."
ARCH_INNER
chmod +x "${ROOT}/root/in-chroot.sh"

# ---------- Pass env + run inside Arch ----------
env -i DEVICE="$DEVICE" HOSTNAME="$HOSTNAME" USERNAME="$USERNAME" TZ="$TZ" LOCALE="$LOCALE" \
  chroot "$ROOT" /bin/bash /root/in-chroot.sh

# ---------- Teardown ----------
for d in dev proc sys run; do umount -R "${ROOT}/$d" || true; done
echo "DONE. You can now boot from ${DEVICE} (Arch + XFCE, Btrfs)."