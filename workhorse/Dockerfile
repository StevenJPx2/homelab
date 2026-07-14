FROM docker.io/cloudflare/sandbox:0.12.3

# Bake the agent runtime into the image so sandboxes don't pay a per-run
# npm install (disk is ephemeral; runtime installs are wasted work).
#
# 1. /opt/agent: Pi CLI + deps.
# 2. /root/.pi/agent: settings.json referencing the Claude-subscription OAuth
#    extension, then run Pi once so IT installs the extension into its own
#    cache at build time (it exits nonzero for lack of auth — that's fine).
#    At runtime only auth.json (short-lived access token) is injected.
RUN mkdir -p /opt/agent /root/.pi/agent \
  && cd /opt/agent \
  && npm init -y >/dev/null \
  && npm install --omit=dev @earendil-works/pi-coding-agent \
  && printf '%s\n' \
    '{"packages":["npm:@gotgenes/pi-anthropic-auth"],"defaultProvider":"anthropic","defaultModel":"claude-sonnet-4-6"}' \
    > /root/.pi/agent/settings.json \
  && (timeout 120 node /opt/agent/node_modules/@earendil-works/pi-coding-agent/dist/cli.js -p -np "warmup" || true) \
  && ls /root/.pi/agent

EXPOSE 8080
