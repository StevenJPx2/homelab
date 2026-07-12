#!/usr/bin/env bash
# macbook-server install, part 2: resume after mount race.
# Disk is already partitioned+formatted. Run as root.
set -euo pipefail

udevadm settle || true

echo "==> Mounting"
mountpoint -q /mnt || mount /dev/sda2 /mnt
mkdir -p /mnt/boot
mountpoint -q /mnt/boot || mount /dev/sda1 /mnt/boot

echo "==> Generating hardware config"
nixos-generate-config --root /mnt

echo "==> Fetching server configuration.nix"
curl -fsSL -o /mnt/etc/nixos/configuration.nix https://paste.rs/Q21wH
grep -q "macbook-server" /mnt/etc/nixos/configuration.nix \
  || { echo "ERROR: downloaded config looks wrong"; exit 1; }

echo "==> Running nixos-install (long download; ROOT password prompt at the end)"
nixos-install

echo
echo "=== DONE ==="
echo "1. Remove the USB stick"
echo "2. Type: reboot"
echo "3. Log in as steven / changeme  (then run: passwd)"
