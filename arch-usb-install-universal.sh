#!/usr/bin/env bash
# arch-usb-install-universal.sh
# Universal (host-agnostic) Arch USB installer using an Arch bootstrap chroot.
# Refactored for safety, modularity, and correctness.
#
# DESCRIPTION:
#   This script installs a full Arch Linux system onto a USB drive (or other target).
#   It works from ANY x86_64 Linux host (Ubuntu, Fedora, etc.) by downloading a minimal
#   Arch "bootstrap" environment, entering it, and using the official 'pacstrap' tool.
#   
#   The Resulting System:
#     - Disk Layout: GPT, BIOS+UEFI compatible (via GRUB).
#     - Root Filesystem: Btrfs with ZSTD compression and @/@home subvolumes.
#     - Desktop: XFCE4 + LightDM.
#     - Network: NetworkManager enabled.
#     - Browser: Firefox.
#
#   Caching:
#     To speed up subsequent runs, this script caches the bootstrap tarball and pacman packages
#     in CACHE_DIR (Default: /var/cache/arch-usb-install-universal).
#     If you wish to reclaim disk space, you can manually delete this directory:
#       sudo rm -rf /var/cache/arch-usb-install-universal
#
# OPTIONS:
#   --device <PATH>     [REQUIRED] The target block device (e.g., /dev/sdb).
#                       WARNING: THIS DEVICE WILL BE ERASED.
#   --hostname <NAME>   Set the hostname (Default: arch-usb).
#   --user <NAME>       Set the non-root username (Default: archuser).
#   --tz <TIMEZONE>     Set the timezone (Default: America/New_York).
#   --locale <LOCALE>   Set the locale (Default: en_US.UTF-8).
#
# EXAMPLE:
#   sudo ./arch-usb-install-universal.sh --device /dev/sdc --user joel --tz Europe/London

set -euo pipefail

# ---------- Configuration Defaults ----------
DEVICE=""
HOSTNAME="${HOSTNAME:-arch-usb}"
USERNAME="${USERNAME:-archuser}"
TZ="${TZ:-America/New_York}"
LOCALE="${LOCALE:-en_US.UTF-8}"

# Use a persistent workspace on disk (not tmpfs) to avoid RAM exhaustion
TMP_BASE="/var/lib/universal-installer-arch-$(date +%s)"
ARCH_ROOT="${TMP_BASE}/arch-bootstrap-root"
ARCH_BOOTSTRAP_URL="${ARCH_BOOTSTRAP_URL:-https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst}"
# Persistent cache directory
CACHE_DIR="${CACHE_DIR:-/var/cache/arch-usb-install-universal}"

# ---------- Logging & Helper Functions ----------
log() { echo -e "\033[1;34m>>> $*\033[0m"; }
error() { echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }
warn() { echo -e "\033[1;33mWARNING: $*\033[0m" >&2; }

cleanup() {
    log "Cleaning up resources..."
    # Recursive unmount using /proc/mounts to find everything under our root
    # sort -r reverses order (deepest first)
    if [ -d "$ARCH_ROOT" ]; then
        grep "$ARCH_ROOT" /proc/mounts | cut -f2 -d" " | sort -r | while read -r mnt; do
             umount -R "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
        done
    fi
    
    # Just in case the root itself is still mounted (though the loop should catch it)
    if mountpoint -q "$ARCH_ROOT"; then
        umount -R "$ARCH_ROOT" 2>/dev/null || true
    fi
    
    # remove workspace
    rm -rf "$TMP_BASE"
}
trap cleanup EXIT

check_root() {
    if [[ $EUID -ne 0 ]]; then
        exec sudo -E bash "$0" "$@"
    fi
}

check_deps() {
    local missing=()
    for cmd in curl tar zstd lsblk blkid wipefs partprobe sgdisk mkfs.vfat mkfs.btrfs; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies on host: ${missing[*]}.\nPlease install them (e.g., arch-install-scripts, btrfs-progs, gptfdisk, dosfstools)."
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device)   DEVICE="$2"; shift 2;;
            --hostname) HOSTNAME="$2"; shift 2;;
            --user)     USERNAME="$2"; shift 2;;
            --tz)       TZ="$2"; shift 2;;
            --locale)   LOCALE="$2"; shift 2;;
            *) error "Unknown argument: $1";;
        esac
    done

    if [[ -z "$DEVICE" ]]; then
        error "--device is required (e.g., --device /dev/sdb)"
    fi
    if [[ ! -b "$DEVICE" ]]; then
        error "Device $DEVICE is not a block device."
    fi
    
    # Safety Check: Root partition
    if lsblk -no MOUNTPOINT "$DEVICE" | grep -q '^/$'; then
        error "Device $DEVICE is currently mounted as root! Aborting immediately."
    fi

    warn "This will ERASE ALL DATA on $DEVICE"
    read -rp "Type 'DESTROY' (all caps) to continue: " confirm
    [[ "$confirm" == "DESTROY" ]] || error "Aborted by user."
}

# ---------- Core Logic ----------

partition_and_format() {
    log "Partitioning $DEVICE (GPT: BIOS+ESP+Btrfs)..."
    
    # Unmount everything on device
    for part in $(lsblk -ln -o NAME "$DEVICE" | tail -n +2); do
        umount -R "/dev/$part" 2>/dev/null || true
    done
    wipefs -a "$DEVICE"

    # 1. BIOS boot (1M) - Type EF02
    # 2. ESP (512M) - Type EF00
    # 3. Root (Rest) - Type 8304 (Linux x86-64 root)
    sgdisk -Z "$DEVICE"
    sgdisk -o \
        -n 1:0:+1MiB   -t 1:EF02 \
        -n 2:0:+512MiB -t 2:EF00 \
        -n 3:0:0       -t 3:8304 \
        "$DEVICE"
    
    partprobe "$DEVICE"
    sleep 2
    
    # Detect partitions (handle /dev/nvme0n1pX vs /dev/sdX case)
    if [[ "$DEVICE" == *"nvme"* ]] || [[ "$DEVICE" == *"mmcblk"* ]]; then
        P_ESP="${DEVICE}p2"
        P_ROOT="${DEVICE}p3"
    else
        P_ESP="${DEVICE}2"
        P_ROOT="${DEVICE}3"
    fi

    log "Formatting partitions..."
    mkfs.vfat -F32 -n "ARCH_EFI" "$P_ESP"
    mkfs.btrfs -f -L "ARCH_ROOT" "$P_ROOT"
    
    # Btrfs Subvolumes
    log "Creating Btrfs subvolumes..."
    # Mount temporarily to create subvols
    mkdir -p "${TMP_BASE}/mnt_tmp"
    mount "$P_ROOT" "${TMP_BASE}/mnt_tmp"
    btrfs subvolume create "${TMP_BASE}/mnt_tmp/@"
    btrfs subvolume create "${TMP_BASE}/mnt_tmp/@home"
    umount "${TMP_BASE}/mnt_tmp"
}

prepare_bootstrap() {
    log "Setting up Arch bootstrap environment at $ARCH_ROOT..."
    mkdir -p "$ARCH_ROOT"
    mkdir -p "$CACHE_DIR"
    
    local bootstrap_file="archlinux-bootstrap-x86_64.tar.zst"
    local cache_path="${CACHE_DIR}/${bootstrap_file}"
    
    if [[ -f "$cache_path" ]]; then
        log "Using cached bootstrap from $cache_path"
    else
        log "Downloading Arch bootstrap to cache..."
        curl -L --fail -o "$cache_path" "$ARCH_BOOTSTRAP_URL"
    fi

    cd "$TMP_BASE"
    log "Extracting bootstrap..."
    tar --zstd -xpf "$cache_path"
    
    # The tarball contains root.x86_64 folder
    # We move it to our target path or just simlink
    if [ -d "root.x86_64" ]; then
        mount --bind "root.x86_64" "$ARCH_ROOT"
    else
        error "Extraction failed: root.x86_64 directory not found."
    fi
    
    # Make the root private for bind mounts
    mount --make-private "$ARCH_ROOT"

    # Bind mounts for chroot functionality
    for d in dev proc sys run; do
        mount --rbind "/$d" "${ARCH_ROOT}/$d"
        mount --make-rslave "${ARCH_ROOT}/$d"
    done
    
    # DNS
    mkdir -p "${ARCH_ROOT}/etc"
    cp /etc/resolv.conf "${ARCH_ROOT}/etc/resolv.conf"
    
    
    # Bind host pacman cache if exists, OR use our persistent cache
    mkdir -p "${ARCH_ROOT}/var/cache/pacman/pkg"
    mkdir -p "${CACHE_DIR}/pkg"
    
    # Mount our persistent cache
    mount --bind "${CACHE_DIR}/pkg" "${ARCH_ROOT}/var/cache/pacman/pkg"
    
    # If host has a cache, maybe we could have used it, but a dedicated cache 
    # for this tool is safer/more predictable across distros.
}

mount_target_in_chroot() {
    log "Mounting target USB inside the bootstrap environment..."
    # We need to mount the target device *inside* the bootstrap root
    # so 'pacstrap' inside can see it at /mnt.
    
    local CHROOT_MNT="${ARCH_ROOT}/mnt"
    mkdir -p "$CHROOT_MNT"
    
    if [[ "$DEVICE" == *"nvme"* ]] || [[ "$DEVICE" == *"mmcblk"* ]]; then
        P_ESP="${DEVICE}p2"
        P_ROOT="${DEVICE}p3"
    else
        P_ESP="${DEVICE}2"
        P_ROOT="${DEVICE}3"
    fi

    # Mount Root (subvol=@)
    mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@ "$P_ROOT" "$CHROOT_MNT"
    
    # Mount Home
    mkdir -p "${CHROOT_MNT}/home"
    mount -o noatime,compress=zstd:3,space_cache=v2,subvol=@home "$P_ROOT" "${CHROOT_MNT}/home"
    
    # Mount Boot
    mkdir -p "${CHROOT_MNT}/boot"
    mount "$P_ESP" "${CHROOT_MNT}/boot"
}

generate_install_script() {
    cat > "${ARCH_ROOT}/root/install_internal.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
TZ="$TZ"
LOCALE="$LOCALE"

echo ">>> [BOOTSTRAP] Initializing pacman keys..."
pacman-key --init
pacman-key --populate archlinux || true # Might fail if keys outdated, but init is key
# Use a geographically diverse mirrorlist
printf 'Server = https://geo.mirror.pkgbuild.com/\$repo/os/\$arch\n' > /etc/pacman.d/mirrorlist

echo ">>> [BOOTSTRAP] Installing installer tools..."
pacman -Sy --noconfirm arch-install-scripts

echo ">>> [BOOTSTRAP] Installing System to /mnt..."
# Packages: Base, Kernel, Firmware, File systems, Network, Tools, Desktop
pacstrap /mnt base linux linux-firmware networkmanager sudo vim btrfs-progs \
    intel-ucode amd-ucode xfce4 xfce4-goodies lightdm lightdm-gtk-greeter \
    firefox grub efibootmgr

echo ">>> [BOOTSTRAP] Generating fstab..."
genfstab -U /mnt > /mnt/etc/fstab

echo ">>> [BOOTSTRAP] Configuring installed system..."
arch-chroot /mnt /bin/bash <<INNER
set -euo pipefail

# Time & Locale
ln -sf /usr/share/zoneinfo/\$TZ /etc/localtime
hwclock --systohc
sed -i "s/^#\$LOCALE/\$LOCALE/" /etc/locale.gen
locale-gen
echo "LANG=\$LOCALE" > /etc/locale.conf
echo "\$HOSTNAME" > /etc/hostname

# Network
echo "127.0.0.1 localhost" >> /etc/hosts
echo "::1       localhost" >> /etc/hosts
systemctl enable NetworkManager

# Users
echo "root:root" | chpasswd
useradd -m -G wheel -s /bin/bash \$USERNAME
echo "\$USERNAME:\$USERNAME" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Initramfs (generic hooks for USB portability)
echo "KEYMAP=us" > /etc/vconsole.conf
echo "FONT=" >> /etc/vconsole.conf
sed -i 's/^HOOKS=.*/HOOKS=(base udev block keyboard keymap autodetect modconf filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# Bootloader
    # We identify the device from the bootstrap environment (where /mnt/boot is mounted)
    # and pass it into the chroot.
    BOOT_DEV=\$(findmnt -n -o SOURCE -T /mnt/boot | sed 's/[0-9]*$//' | sed 's/p$//')

    echo ">>> [INNER] Installing GRUB to \$BOOT_DEV..."
    # BIOS
    grub-install --target=i386-pc --recheck --removable "\$BOOT_DEV"
# UEFI
grub-install --target=x86_64-efi --efi-directory=/boot --removable --recheck

grub-mkconfig -o /boot/grub/grub.cfg

# DM
systemctl enable lightdm
INNER

echo ">>> [BOOTSTRAP] Install Complete."
EOF
    chmod +x "${ARCH_ROOT}/root/install_internal.sh"
}

run_install() {
    log "Running installation inside bootstrap environment..."
    # We strip environment variables to ensure clean execution, passing only explicit ones
    env -i HOSTNAME="$HOSTNAME" USERNAME="$USERNAME" TZ="$TZ" LOCALE="$LOCALE" \
        chroot "$ARCH_ROOT" /bin/bash /root/install_internal.sh
}

# ---------- Main Execution ----------
main() {
    check_root
    parse_args "$@"
    check_deps
    
    partition_and_format
    prepare_bootstrap
    mount_target_in_chroot
    generate_install_script
    run_install
    
    log "SUCCESS! Arch Linux installed on $DEVICE."
    log "Credentials:"
    log "  Root: root / root"
    log "  User: $USERNAME / $USERNAME"
}

main "$@"