#!/usr/bin/env bash
# Deploy macbook-server/configuration.nix from this repo to the server
# and apply it with nixos-rebuild switch.
set -euo pipefail

HOST="${1:-macbook-server}"          # hostname / tailnet name / IP
SRC="$(dirname "$0")/configuration.nix"

echo "==> Deploying $SRC to steven@$HOST"
scp "$SRC" "steven@$HOST:/tmp/configuration.nix"
ssh -t "steven@$HOST" "
  sudo cp /tmp/configuration.nix /etc/nixos/configuration.nix &&
  sudo nixos-rebuild switch
"
echo "==> Done. Rollback anytime with: ssh steven@$HOST sudo nixos-rebuild switch --rollback"
