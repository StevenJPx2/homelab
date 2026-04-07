# Homelab Docker Compose Stack

Self-hosted services running on Docker with OrbStack, featuring automatic startup on boot.

## Services

| Service | Local URL | Direct Port | Description |
|---------|-----------|-------------|-------------|
| Home Assistant | http://ha.home.local | :8123 | Smart home automation |
| Pi-hole | http://pihole.home.local/admin | :8080 | DNS ad blocking |
| Portainer | https://portainer.home.local | :9443 | Docker management |
| Uptime Kuma | http://uptime.home.local | :3001 | Service monitoring |
| Homepage | http://home.home.local | :3000 | Dashboard |
| Caddy | - | :80, :443 | Reverse proxy |

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         macOS                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   ┌─────────────┐                                               │
│   │  OrbStack   │ ◄── Starts on login (Login Item)              │
│   │  (Docker)   │                                               │
│   └──────┬──────┘                                               │
│          │                                                       │
│          ▼                                                       │
│   ┌─────────────────────────────────────────────────────────┐   │
│   │              Docker Network: homelab                     │   │
│   │                                                          │   │
│   │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐   │   │
│   │  │ Pi-hole  │ │  Caddy   │ │Portainer │ │ Homepage │   │   │
│   │  │  :8080   │ │  :80/443 │ │  :9443   │ │  :3000   │   │   │
│   │  │  :53     │ │          │ │          │ │          │   │   │
│   │  └──────────┘ └──────────┘ └──────────┘ └──────────┘   │   │
│   │                                                          │   │
│   │  ┌──────────┐ ┌────────────────────────────────────┐   │   │
│   │  │  Uptime  │ │        Home Assistant              │   │   │
│   │  │   Kuma   │ │     (network_mode: host)           │   │   │
│   │  │  :3001   │ │          :8123                     │   │   │
│   │  └──────────┘ └────────────────────────────────────┘   │   │
│   │                                                          │   │
│   └─────────────────────────────────────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Auto-Start on Boot

All services automatically start when your Mac boots. Here's how it works:

### The Auto-Start Chain

```
Mac boots
    │
    ▼
macOS Login
    │
    ▼
OrbStack launches (Login Item)
    │
    ▼
Docker daemon starts
    │
    ▼
Containers with restart policy start
    │
    ▼
All homelab services running!
```

### Restart Policy

All containers are configured with `restart: unless-stopped`:

```yaml
restart: unless-stopped
```

This means:
- **Auto-start on boot**: Containers start when Docker daemon starts
- **Auto-restart on crash**: If a container crashes, Docker automatically restarts it
- **Manual stop respected**: If you run `docker stop <container>`, it stays stopped until you manually start it

### Verifying Auto-Start Setup

```bash
# Check OrbStack is in login items
osascript -e 'tell application "System Events" to get the name of every login item'

# Check container restart policies
docker inspect --format '{{.Name}}: {{.HostConfig.RestartPolicy.Name}}' \
  homeassistant pihole portainer caddy uptime-kuma homepage
```

### Adding OrbStack to Login Items (if needed)

```bash
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/OrbStack.app", hidden:false}'
```

## Quick Start

### 1. Configure Environment

```bash
# Get your LAN IP
just ip

# Copy and edit the environment file
cp .env.example .env
# Edit .env: set LAN_IP and PIHOLE_PASSWORD
```

### 2. Start Services

```bash
just up
```

### 3. Configure Local DNS (Optional)

For `*.home.local` domains to work, run:

```bash
sudo ./scripts/setup-hosts.sh
```

This adds entries to `/etc/hosts` for local domain resolution.

### 4. Access Services

**Direct access (always works):**
- Homepage: http://localhost:3000
- Home Assistant: http://localhost:8123
- Pi-hole: http://localhost:8080/admin
- Portainer: https://localhost:9443
- Uptime Kuma: http://localhost:3001

**Via local domains (after DNS setup):**
- Homepage: http://home.home.local
- Home Assistant: http://ha.home.local
- Pi-hole: http://pihole.home.local/admin
- Portainer: https://portainer.home.local
- Uptime Kuma: http://uptime.home.local

## CLI Commands

All homelab management is done via `just` commands:

```bash
# Get your LAN IP
just ip

# Show Pi-hole DNS setup instructions
just dns

# Start all services
just up

# Start specific service
just up homeassistant

# Stop all services
just down

# Check status of all services
just status

# View logs (follow mode)
just logs -f pihole

# View last 50 lines of logs
just logs -t 50 homeassistant

# Restart a service
just restart pihole

# Update all images and restart
just update

# Start Cloudflare tunnel for internet access
just tunnel

# List all commands
just --list
```

## Internet Access (Cloudflare Tunnel)

Expose services to the internet via Cloudflare Quick Tunnels:

```bash
just tunnel
```

This creates a temporary public URL (changes on restart). 

**Note**: Cloudflare tunnels require outbound access to port 7844 (QUIC). Some networks/ISPs block this port. If the tunnel fails to connect, try from a different network.

For a permanent URL, create a free Cloudflare account and set up a named tunnel.

## Home Assistant Setup

### Existing Configuration

Your Home Assistant config is preserved at:
```
~/homeassistant
```

The Docker Compose setup mounts this directory, so all your existing automations, integrations, and settings are retained.

### Adding Devices (Denon AVR, etc.)

Docker on macOS doesn't support true host networking for device discovery (mDNS/SSDP). Add devices manually by IP:

1. Find the device's IP address (check your router or device settings)
2. Go to Home Assistant → Settings → Devices & Services
3. Click "Add Integration"
4. Search for the integration (e.g., "Denon AVR")
5. Enter the device's IP address

### Network Mode

Home Assistant runs with `network_mode: host` to maximize compatibility with local device discovery. While not perfect on macOS, it provides better results than bridge networking.

## Pi-hole Configuration

### Web Interface

Access at: http://localhost:8080/admin

Default password is set in `.env` file (`PIHOLE_PASSWORD`).

### Local DNS Records

Custom DNS records are stored in:
```
pihole/etc-dnsmasq.d/02-local-dns.conf
```

To add new local domains, edit this file:
```
address=/myservice.home.local/192.168.0.142
```

Then reload DNS:
```bash
docker exec pihole pihole reloaddns
```

### Static IP

Pi-hole has a static IP (`172.20.0.53`) on the Docker network to ensure consistent DNS resolution.

## Reverse Proxy (Caddy)

Caddy handles routing for `*.home.local` domains. Configuration is in:
```
caddy/Caddyfile
```

To add a new service:
```caddyfile
myservice.home.local {
    reverse_proxy myservice:8080
}
```

Then restart Caddy:
```bash
just restart caddy
```

## File Structure

```
.
├── Justfile                    # Task runner commands
├── docker-compose.yml          # All services defined here
├── .env                        # Environment variables (gitignored)
├── .env.example                # Template for .env
├── README.md                   # This file
├── caddy/
│   ├── Caddyfile               # Reverse proxy configuration
│   ├── data/                   # Caddy data (gitignored)
│   └── config/                 # Caddy config (gitignored)
├── homepage/
│   └── config/
│       ├── services.yaml       # Dashboard service links
│       ├── settings.yaml       # Dashboard settings
│       └── bookmarks.yaml      # Optional bookmarks
├── scripts/
│   ├── homelab.py              # CLI management tool
│   └── setup-hosts.sh          # Add domains to /etc/hosts
├── pihole/                     # Pi-hole data (gitignored)
│   ├── etc-pihole/
│   └── etc-dnsmasq.d/
├── uptime-kuma/                # Uptime Kuma data (gitignored)
├── portainer/                  # Portainer data (gitignored)
└── cloudflared/                # Cloudflared data (gitignored)
```

## Troubleshooting

### Services not starting after reboot

1. Check OrbStack is running:
   ```bash
   pgrep -l OrbStack
   ```

2. Check OrbStack is in login items:
   ```bash
   osascript -e 'tell application "System Events" to get the name of every login item'
   ```

3. Manually start OrbStack:
   ```bash
   open -a OrbStack
   ```

4. Check container status:
   ```bash
   just status
   ```

### Port 53 conflict

If Pi-hole can't bind to port 53:
```bash
sudo lsof -i :53
```

OrbStack usually handles this, but if there's a conflict, you may need to stop conflicting services.

### Services not accessible via *.home.local

1. Run the hosts setup script:
   ```bash
   sudo ./scripts/setup-hosts.sh
   ```

2. Flush DNS cache:
   ```bash
   sudo dscacheutil -flushcache
   sudo killall -HUP mDNSResponder
   ```

3. Verify the reverse proxy is working:
   ```bash
   curl -H "Host: ha.home.local" http://localhost:80
   ```

### Container keeps crashing

Check logs for the specific container:
```bash
just logs -t 100 <service-name>
```

Common issues:
- Missing environment variables (check `.env` file)
- Port conflicts with other services
- Permission issues with mounted volumes
- Insufficient memory

### Cloudflare tunnel not connecting

The tunnel requires outbound access to Cloudflare's edge servers on port 7844 (QUIC). If blocked:

1. Check if port 7844 is accessible:
   ```bash
   nc -zv 198.41.200.23 7844
   ```

2. Try from a different network (mobile hotspot, etc.)

3. Check tunnel logs:
   ```bash
   docker logs cloudflared
   ```

## Updating Services

### Update all containers

```bash
just update
```

This pulls the latest images and restarts all containers.

### Update specific container

```bash
docker compose pull <service-name>
docker compose up -d <service-name>
```

## Backup

### What to backup

- `.env` - Environment configuration
- `caddy/Caddyfile` - Reverse proxy config
- `homepage/config/` - Dashboard configuration
- `~/homeassistant/` - Home Assistant config

### What's auto-generated (no backup needed)

- `pihole/` - Can be recreated
- `portainer/` - Can be recreated  
- `uptime-kuma/` - Monitoring data (recreate monitors if needed)
- `caddy/data/` and `caddy/config/` - Auto-generated
