# Homelab management commands

# Run homelab CLI
[private]
cli *args:
  python3 scripts/homelab.py {{args}}

# Get LAN IP address
ip:
  just cli ip

# Show Pi-hole DNS setup instructions
dns:
  just cli dns

# Start Cloudflare tunnel
tunnel:
  just cli tunnel

# Show status of all services
status:
  just cli status

# Start services
up *service:
  just cli up {{service}}

# Stop services
down *service:
  just cli down {{service}}

# Show service logs
logs *args:
  just cli logs {{args}}

# Restart services
restart *service:
  just cli restart {{service}}

# Pull latest images and restart
update:
  just cli update
