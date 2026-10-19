#!/usr/bin/env bash
# Deploy nixos/ from this repo to the server and apply with nixos-rebuild switch.
set -euo pipefail

HOST="${1:-macbook-server}"          # hostname / tailnet name / IP
DIR="$(dirname "$0")"

echo "==> Deploying nixos/ to steven@$HOST"
# Sync the NixOS configuration.
scp "$DIR/configuration.nix" "steven@$HOST:/tmp/"
ssh -t "steven@$HOST" "
  sudo cp /tmp/configuration.nix /etc/nixos/ &&
  sudo nixos-rebuild switch
"
echo "==> Done. Rollback anytime with: ssh steven@$HOST sudo nixos-rebuild switch --rollback"
