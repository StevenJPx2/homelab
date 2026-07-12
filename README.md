# Homelab

The entire homelab is a single NixOS machine — an A1278 MacBook Pro (2011/2012,
8GB RAM, SSD) running headless with the lid closed. Everything it runs is
declared in [`nixos/configuration.nix`](nixos/configuration.nix); this repo is
the source of truth.

## Server

| | |
|---|---|
| Host | `macbook-server` — `192.168.0.40` (LAN, DHCP-reserved) / `100.104.65.112` (Tailscale) |
| OS | NixOS 25.11, user `steven` |
| Access | `ssh steven@192.168.0.40` (key auth) or via tailnet from anywhere |

## Services

| Service | URL | Notes |
|---|---|---|
| Glance | http://192.168.0.40:8080 | Dashboard: server vitals (CPU/RAM/disk/temp) + service monitors |
| AdGuard Home | http://192.168.0.40 | Network DNS + ad blocking (router DHCP hands out `.40` as DNS) |
| Home Assistant | http://192.168.0.40:8123 · https://ha.stevenjohn.co | Public URL via Cloudflare Tunnel on the server |
| Syncthing | http://192.168.0.40:8384 | File sync |

## Deploying changes

```sh
# 1. Edit nixos/configuration.nix
# 2. Apply to the server:
./nixos/deploy.sh            # uses host "macbook-server" (tailnet)
./nixos/deploy.sh 192.168.0.40   # or by IP
```

The deploy copies the config and runs `nixos-rebuild switch` — atomic, with
rollback: `ssh steven@... sudo nixos-rebuild switch --rollback`, or pick an
older generation from the boot menu.

## Secrets (not in git)

| File (on server) | Purpose |
|---|---|
| `/var/lib/cloudflared/env` | `TUNNEL_TOKEN=…` for the stevenjohn.co Cloudflare Tunnel |

## Bare-metal reinstall

1. Boot a NixOS ISO (hold ⌥, pick EFI Boot), partition GPT + ESP + ext4
   (see `nixos/install.sh` for the exact commands).
2. `nixos-generate-config --root /mnt`, drop in `nixos/configuration.nix`.
3. `nixos-install`, reboot, re-copy the secrets above, `tailscale up`.
4. Restore Home Assistant data into `/var/lib/hass` if migrating.

## History

Until 2026 this repo was a Docker Compose stack (Pi-hole, Portainer, Caddy,
Homepage, Uptime Kuma, cloudflared) on a laptop via OrbStack. It was replaced
wholesale by the NixOS server; the old stack lives in git history before the
`nixos-migration` commit.
