#!/usr/bin/env bash
# alpine-usb-persistent-universal.sh
# Universal (host-agnostic) Alpine USB installer: diskless + LBU persistence + XFCE
# Refactored for safety, modularity, and correct persistence logic.
#
# DESCRIPTION:
#   This script creates a bootable, persistent Alpine Linux USB drive from any x86_64 Linux host.
#   It uses a 'diskless' mode with LBU (Local Backup Utility) and a persistent cache for packages.
#   This means the system runs from RAM, but changes to /etc (via LBU) and installed packages
#   (via apk cache) are saved to the USB stick and restored on boot.
#   It automatically partitions the target device, installs a minimal base, sets up XFCE desktop,
#   and configures persistence.
#
#   Caching:
#     Resources (minirootfs, ISO, packages) are cached in /var/cache/alpine-usb-installer
#     to speed up subsequent runs.
#
# OPTIONS:
#   --device <PATH>       [REQUIRED] The target block device to install to (e.g., /dev/sdb).
#                         WARNING: THIS DEVICE WILL BE WIPED.
#   --hostname <NAME>     Set the hostname of the installed system (Default: alpine-usb).
#   --user <NAME>         Set the non-root username (Default: alpine).
#   --tz <TIMEZONE>       Set the timezone (Default: America/New_York).
#   --keymap <LAYOUT>     Set the keyboard layout (Default: us).
#   --iso-url <URL>       Override the source Alpine ISO URL (used for bootloader files).
#   --miniroot-url <URL>  Override the source Alpine Minirootfs URL (used for chroot).
#
# EXAMPLE:
#   sudo ./alpineUSB.sh --device /dev/sdb --hostname my-alpine --tz Europe/London

set -euo pipefail

# ---------- Configuration Defaults ----------
DEVICE=""
HOSTNAME="${HOSTNAME:-alpine-usb}"
USERNAME="${USERNAME:-alpine}"
TZ="${TZ:-America/New_York}"
KEYMAP="${KEYMAP:-us}"
# Alpine 3.23.3 standard ISO and minirootfs
ALPINE_VER="3.23.3"
ALPINE_ARCH="x86_64"
ALPINE_ISO_URL="${ALPINE_ISO_URL:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${ALPINE_ARCH}/alpine-standard-${ALPINE_VER}-${ALPINE_ARCH}.iso}"
MINIROOT_URL="${MINIROOT_URL:-https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${ALPINE_ARCH}/alpine-minirootfs-${ALPINE_VER}-${ALPINE_ARCH}.tar.gz}"

# Persistent cache
CACHE_DIR="${CACHE_DIR:-/var/cache/alpine-usb-installer}"

TMP_BASE="/tmp/alpine-installer-$(date +%s)"
ALP_CHROOT="${TMP_BASE}/alpine-root"

# ---------- Logging & Helper Functions ----------
log() { echo -e "\033[1;34m>>> $*\033[0m"; }
error() { echo -e "\033[1;31mERROR: $*\033[0m" >&2; exit 1; }
warn() { echo -e "\033[1;33mWARNING: $*\033[0m" >&2; }

cleanup() {
    log "Cleaning up resources..."
    # Unmount chroot binds
    if mountPOINT=$(mount | grep "${ALP_CHROOT}" | awk '{print $3}' | sort -r); then
        for m in $mountPOINT; do
            umount -R "$m" || true
        done
    fi
    # Remove temp dir
    rm -rf "$TMP_BASE"
}
trap cleanup EXIT

check_deps() {
    local missing=()
    for cmd in curl tar lsblk blkid wipefs partprobe sfdisk mkfs.vfat mkfs.f2fs; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required dependencies on host: ${missing[*]}.\nPlease install them via your package manager (e.g., f2fs-tools, dosfstools, util-linux)."
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        exec sudo -E bash "$0" "$@"
    fi
}

# ---------- Argument Parsing ----------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device) DEVICE="$2"; shift 2;;
            --hostname) HOSTNAME="$2"; shift 2;;
            --user) USERNAME="$2"; shift 2;;
            --tz) TZ="$2"; shift 2;;
            --keymap) KEYMAP="$2"; shift 2;;
            --iso-url) ALPINE_ISO_URL="$2"; shift 2;;
            --miniroot-url) MINIROOT_URL="$2"; shift 2;;
            *) error "Unknown argument: $1";;
        esac
    done

    if [[ -z "$DEVICE" ]]; then
        error "--device is required (e.g., --device /dev/sdb)"
    fi

    if [[ ! -b "$DEVICE" ]]; then
        error "Device $DEVICE is not a block device."
    fi

    # Safety check: Prevent targeting system drive
    if lsblk -no MOUNTPOINT "$DEVICE" | grep -q '^/$'; then
        error "Device $DEVICE is currently mounted as root! Aborting immediately."
    fi

    warn "This will ERASE ALL DATA on $DEVICE"
    read -rp "Type 'DESTROY' (all caps) to continue: " confirm
    [[ "$confirm" == "DESTROY" ]] || error "Aborted by user."
}

# ---------- Core Logic ----------
prepare_chroot() {
    log "Creating build environment at $ALP_CHROOT..."
    mkdir -p "$ALP_CHROOT"
    
    # Cache setup
    mkdir -p "${CACHE_DIR}/apk"
    local mini_file="alpine-minirootfs-${ALPINE_VER}-${ALPINE_ARCH}.tar.gz"
    local iso_file="alpine-standard-${ALPINE_VER}-${ALPINE_ARCH}.iso"
    
    # 1. Minirootfs
    if [ ! -f "${CACHE_DIR}/${mini_file}" ]; then
        log "Downloading Alpine minirootfs to cache..."
        curl -L --fail -o "${CACHE_DIR}/${mini_file}" "$MINIROOT_URL"
    else
        log "Using cached minirootfs..."
    fi
    
    # 2. ISO (Pre-download for inner script)
    if [ ! -f "${CACHE_DIR}/${iso_file}" ]; then
        log "Downloading Alpine ISO to cache (for boot files)..."
        curl -L --fail -o "${CACHE_DIR}/${iso_file}" "$ALPINE_ISO_URL"
    else
        log "Using cached Alpine ISO..."
    fi
    
    log "Extracting minirootfs..."
    tar -xzf "${CACHE_DIR}/${mini_file}" -C "$ALP_CHROOT"
    
    log "Setting up bind mounts..."
    for d in dev proc sys; do
        mount --rbind "/$d" "${ALP_CHROOT}/$d"
        mount --make-rslave "${ALP_CHROOT}/$d"
    done
    
    # Copy resolv.conf for networking
    mkdir -p "${ALP_CHROOT}/etc"
    cp /etc/resolv.conf "${ALP_CHROOT}/etc/resolv.conf"
    
    # Mount Cache for inner script usage
    # 1. Mount the whole cache dir to /mnt/cache inside chroot so we can access the ISO
    mkdir -p "${ALP_CHROOT}/mnt/cache"
    mount --bind "$CACHE_DIR" "${ALP_CHROOT}/mnt/cache"
    
    # 2. Mount APK cache to /etc/apk/cache (standard location) so 'apk' uses it
    mkdir -p "${ALP_CHROOT}/etc/apk/cache"
    mount --bind "${CACHE_DIR}/apk" "${ALP_CHROOT}/etc/apk/cache"
}

generate_inner_script() {
    cat > "${ALP_CHROOT}/root/install_internal.sh" <<EOF
#!/bin/sh
set -eu
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Variables passed from host
DEVICE="$DEVICE"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
TZ="$TZ"
KEYMAP="$KEYMAP"
ALPINE_VER="$ALPINE_VER"
ALPINE_ARCH="$ALPINE_ARCH"
# ISO is now mounted at /mnt/cache/alpine-standard-...
ISO_PATH="/mnt/cache/alpine-standard-${ALPINE_VER}-${ALPINE_ARCH}.iso"

echo ">>> [CHROOT] Initializing..."

# 1. Setup APK repositories
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main" > /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/latest-stable/community" >> /etc/apk/repositories
apk update

# 2. Install minimal tools for partitioning/formatting
apk add --no-cache alpine-conf e2fsprogs f2fs-tools dosfstools util-linux tzdata curl

# 3. Partitioning
echo ">>> [CHROOT] Partitioning \$DEVICE..."
wipefs -a "\$DEVICE"
# Partition 1: 1G FAT32 (Boot/Alpine System)
# Partition 2: Remaining F2FS (Data/Home)
sfdisk "\$DEVICE" <<sfdisk_EOF
label: dos
,1G,c,*
,,83
sfdisk_EOF

sleep 2
mdev -s # Rescan devices
partprobe "\$DEVICE" || true

P1="\${DEVICE}1"
P2="\${DEVICE}2"

mkfs.vfat -F32 -n ALPINE_SYS "\$P1"
mkfs.f2fs -f -l ALPINE_DATA "\$P2"

# 4. Mount for setup
mkdir -p /media/trueroot /media/home
mount "\$P1" /media/trueroot
mount "\$P2" /media/home
mkdir -p /media/trueroot/cache

# 5. Bootloader Setup (syslinux/grub)
# We need to extract kernel/initramfs from the standard ISO to make it bootable easily
# using the setup-bootable script which usually expects an ISO source.
echo ">>> [CHROOT] Using cached Alpine ISO..."
mkdir -p /media/iso
mount -o loop,ro "\$ISO_PATH" /media/iso

# Ensure syslinux and grub are available
apk add --no-cache syslinux grub grub-efi

echo ">>> [CHROOT] Installing bootloader (syslinux)..."
# setup-bootable usage: setup-bootable [source] [dest]
# This copies files from ISO and installs syslinux.
setup-bootable /media/iso /media/trueroot

umount /media/iso

# 6. Configure Persistence (CRITICAL STEP)
# We configure apkcache FIRST so subsequent installs are cached to USB
echo ">>> [CHROOT] Configuring Persistence..."

# LBU persistence (overlay)
setup-lbu trueroot

# APK Cache persistence
# By linking /etc/apk/cache to /media/trueroot/cache
setup-apkcache /media/trueroot/cache

# 7. Install Desktop & Users (These will now be cached!)
echo ">>> [CHROOT] Installing XFCE and tools..."
apk add lightdm-gtk-greeter xfce4 xfce4-terminal firefox adwaita-icon-theme

# 8. System Configuration
setup-keymap "\$KEYMAP"
setup-timezone -z "\$TZ"
echo "\$HOSTNAME" > /etc/hostname

# Network (Basic DHCP)
echo "auto lo" > /etc/network/interfaces
echo "iface lo inet loopback" >> /etc/network/interfaces
echo "auto eth0" >> /etc/network/interfaces
echo "iface eth0 inet dhcp" >> /etc/network/interfaces

rc-update add networking boot
rc-update add dbus default
rc-update add lightdm default

# User Setup
echo "Creating user \$USERNAME..."
adduser -D -G wheel "\$USERNAME"
echo "\$USERNAME:alpine" | chpasswd
echo "root:root" | chpasswd

# 9. Verify Fstab for Persistence
# setup-bootable/lbu usually handles the overlay mounts, but we explicitly need /home
UUID_P2=\$(blkid -s UUID -o value "\$P2")
if ! grep -q "/home" /etc/fstab; then
    echo "UUID=\$UUID_P2 /home f2fs defaults,noatime 0 0" >> /etc/fstab
fi

# 10. Commit Changes
echo ">>> [CHROOT] Committing LBU changes..."
lbu commit -d

# Unmount
umount /media/trueroot
umount /media/home

echo ">>> [CHROOT] Success."
EOF
    chmod +x "${ALP_CHROOT}/root/install_internal.sh"
}

run_chroot() {
    log "Entering chroot environment..."
    chroot "$ALP_CHROOT" /bin/sh /root/install_internal.sh
}

# ---------- Main Execution ----------
main() {
    check_root
    parse_args "$@"
    check_deps
    prepare_chroot
    generate_inner_script
    run_chroot
    log "Done! Your Alpine USB is ready on $DEVICE."
}

main "$@"