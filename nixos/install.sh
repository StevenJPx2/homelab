#!/usr/bin/env bash
# NixOS install script for A1278 MacBook Pro -> macbook-server
# Wipes /dev/sda entirely. Run as root from the NixOS live USB.
set -euo pipefail

DISK=/dev/sda
CONFIG_URL="https://paste.rs/Q21wH"

echo "=== macbook-server installer ==="

# --- Safety checks ---
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run as root (sudo -i first)"; exit 1
fi

if [[ ! -d /sys/firmware/efi ]]; then
  echo "ERROR: not booted in EFI mode. Reboot holding Option and pick 'EFI Boot'."; exit 1
fi

if [[ ! -b $DISK ]]; then
  echo "ERROR: $DISK not found"; exit 1
fi

# Refuse to run against the live USB (it has the /iso mount)
if lsblk -no MOUNTPOINTS "$DISK" | grep -q iso; then
  echo "ERROR: $DISK looks like the installer USB, not the SSD!"; exit 1
fi

if ! ping -c1 -W3 cache.nixos.org >/dev/null 2>&1; then
  echo "ERROR: no internet. Check the Ethernet cable."; exit 1
fi

echo
echo "About to ERASE EVERYTHING on:"
lsblk -o NAME,SIZE,MODEL "$DISK"
echo
read -rp "Type YES to wipe $DISK and install NixOS: " confirm
[[ "$confirm" == "YES" ]] || { echo "Aborted."; exit 1; }

# --- Partition ---
echo "==> Partitioning $DISK"
umount -R /mnt 2>/dev/null || true
parted -s "$DISK" -- mklabel gpt
parted -s "$DISK" -- mkpart ESP fat32 1MB 512MB
parted -s "$DISK" -- set 1 esp on
parted -s "$DISK" -- mkpart root ext4 512MB 100%
sleep 2  # let the kernel re-read the partition table

# --- Format ---
echo "==> Formatting"
mkfs.fat -F32 -n BOOT "${DISK}1"
mkfs.ext4 -F -L nixos "${DISK}2"

# --- Mount ---
# udevadm settle avoids the by-label race right after mkfs (symlinks may not
# exist yet); mount by device name for the same reason. Idempotent on re-run.
echo "==> Mounting"
udevadm settle || true
mountpoint -q /mnt || mount "${DISK}2" /mnt
mkdir -p /mnt/boot
mountpoint -q /mnt/boot || mount "${DISK}1" /mnt/boot

# --- Config ---
echo "==> Generating hardware config"
nixos-generate-config --root /mnt

echo "==> Fetching server configuration.nix"
curl -fsSL -o /mnt/etc/nixos/configuration.nix "$CONFIG_URL"
grep -q "macbook-server" /mnt/etc/nixos/configuration.nix \
  || { echo "ERROR: downloaded config looks wrong"; exit 1; }

# --- Install ---
echo "==> Running nixos-install (long download; you'll be asked for a ROOT password at the end)"
nixos-install

echo
echo "=== DONE ==="
echo "1. Remove the USB stick"
echo "2. Type: reboot"
echo "3. Log in as steven / changeme  (then run: passwd)"
