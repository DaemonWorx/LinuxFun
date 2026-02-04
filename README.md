# LinuxFun ISO/USB Installers

This repository contains **host-agnostic** scripts to create fully functional, persistent Arch Linux and Alpine Linux USB drives from *any* x86_64 Linux host (Ubuntu, Fedora, Debian, etc.).

## Scripts

### 1. `arch-usb-install-universal.sh`
Installs a full, persistent **Arch Linux** system onto a USB drive.

- **Type**: Full Installation (Persistent Root).
- **Filesystem**: Btrfs with ZSTD compression.
- **Boot**: Hybrid (BIOS + UEFI).
- **Desktop**: XFCE4 + LightDM.
- **Features**:
    - **Host Agnostic**: Uses an efficient Arch Bootstrap chroot to install; does not require Arch on the host.
    - **Caching**: Caches the Arch bootstrap and pacman packages in `/var/cache/arch-usb-install-universal` for fast subsequent builds.
    - **Safe**: Checks specifically for targeting root devices to prevent accidents.

#### Usage
```bash
sudo ./arch-usb-install-universal.sh --device /dev/sdX --user myuser --tz America/New_York
```

### 2. `alpine-usb-install-universal.sh`
Installs **Alpine Linux** in "Diskless Mode" with persistence.

- **Type**: Diskless (Ramdisk) with Data Persistence (LBU).
- **Filesystem**: FAT32 (Boot) + F2FS (Data/Home).
- **Boot**: Hybrid (Bio + UEFI).
- **Desktop**: XFCE4.
- **Features**:
    - **Lightning Fast**: Runs completely from RAM.
    - **Persistence**: 
        - `/etc` changes saved via LBU (Local Backup Utility).
        - `/home` and `/var/cache/apk` persisted to the F2FS partition.
    - **Caching**: Caches Alpine ISO, Minirootfs, and APK packages in `/var/cache/alpine-usb-installer`.

#### Usage
```bash
sudo ./alpine-usb-install-universal.sh --device /dev/sdX --hostname alpine-stick
```

## Prerequisities
Both scripts require standard linux tools (which they check for): `curl`, `tar`, `lsblk`, `mkfs.vfat`, etc.
Root privileges (`sudo`) are required to partition drives and mount chroots.

## Caching & Cleanup
To speed up repeat runs, these scripts create persistent caches in `/var/cache/`.
To reclaim space, you can run:
```bash
sudo rm -rf /var/cache/arch-usb-install-universal
sudo rm -rf /var/cache/alpine-usb-installer
```
