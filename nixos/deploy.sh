#!/usr/bin/env bash
# Deploy nixos/ from this repo to the server and apply with nixos-rebuild switch.
set -euo pipefail

HOST="${1:-macbook-server}"          # hostname / tailnet name / IP
DIR="$(dirname "$0")"

echo "==> Deploying nixos/ to steven@$HOST"
# Sync every file the config references (configuration.nix reads sibling files
# like pi-runner.mjs, token-push.mjs and pi-extensions/ at build time).
scp -r "$DIR/configuration.nix" "$DIR"/*.mjs "$DIR/pi-extensions" "steven@$HOST:/tmp/"
ssh -t "steven@$HOST" "
  sudo cp /tmp/configuration.nix /tmp/*.mjs /etc/nixos/ &&
  sudo rm -rf /etc/nixos/pi-extensions &&
  sudo cp -r /tmp/pi-extensions /etc/nixos/ &&
  sudo nixos-rebuild switch
"
echo "==> Done. Rollback anytime with: ssh steven@$HOST sudo nixos-rebuild switch --rollback"
