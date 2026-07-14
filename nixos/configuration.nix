{ config, pkgs, ... }:
{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelParams = [ "consoleblank=60" ];  # blank screen after 60s

  networking.hostName = "macbook-server";

  # --- Headless laptop behavior ---
  services.logind.lidSwitch = "ignore";
  services.logind.lidSwitchExternalPower = "ignore";
  services.mbpfan.enable = true;              # MacBook fan control

  # --- Remote access ---
  services.openssh.enable = true;
  services.tailscale = {
    enable = true;
    # Don't let Tailscale hijack DNS — the server resolves via its own AdGuard
    # (localhost:53). MagicDNS-over-100.100.100.100 was failing to forward
    # public queries, breaking all outbound name resolution (e.g. Anthropic API).
    extraUpFlags = [ "--accept-dns=false" ];
  };

  # --- AdGuard Home (DNS :53, web UI :80 — chosen in setup wizard) ---
  services.adguardhome = {
    enable = true;
    openFirewall = false;  # wizard moved UI to :80; opened explicitly below
  };

  # --- Home Assistant (web UI :8123) ---
  # extraComponents list = official NixOS wiki onboarding set
  services.home-assistant = {
    enable = true;
    extraComponents = [
      "analytics"
      "google_translate"
      "met"             # weather, required by onboarding
      "radio_browser"
      "shopping_list"
      "isal"            # fast zlib compression
      "esphome"
      "tuya"            # migrated devices use it
      "bluetooth"
      "kodi"
      "heos"
      "androidtv_remote"
    ];
    config = {
      # https://www.home-assistant.io/integrations/default_config/
      default_config = {};
      http = {
        server_host = "0.0.0.0";
        server_port = 8123;
        # cloudflared (ha.stevenjohn.co) runs on this same host
        use_x_forwarded_for = true;
        trusted_proxies = [ "127.0.0.1" "::1" ];
      };
      # Migrated from the old docker setup — UI-editable automations
      "automation ui" = "!include automations.yaml";
      "script ui" = "!include scripts.yaml";
      "scene ui" = "!include scenes.yaml";
    };
  };

  # Ensure the include files exist so HA doesn't fail on first start
  systemd.tmpfiles.rules = [
    "f /var/lib/hass/automations.yaml 0644 hass hass"
    "f /var/lib/hass/scripts.yaml 0644 hass hass"
    "f /var/lib/hass/scenes.yaml 0644 hass hass"
  ];

  # --- ntfy push notifications (ntfy.stevenjohn.co via tunnel, local :8093) ---
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.stevenjohn.co";
      listen-http = "127.0.0.1:8093";   # only reachable via cloudflared/localhost
      behind-proxy = true;
      auth-file = "/var/lib/ntfy-sh/user.db";
      auth-default-access = "deny-all";  # users/tokens only — it's on the public internet
      upstream-base-url = "https://ntfy.sh";  # instant iOS push via APNS relay
    };
  };

  # --- Restic encrypted backups → Backblaze B2, daily 03:00 ---
  # Secrets (never in git):
  #   /var/lib/restic.env  — B2_ACCOUNT_ID / B2_ACCOUNT_KEY
  #   /var/lib/restic.pass — repo encryption password (KEEP A COPY OFF-SERVER!)
  services.restic.backups.b2 = {
    initialize = true;
    repository = "b2:steven-homelab-backup:macbook-server";
    environmentFile = "/var/lib/restic.env";
    passwordFile = "/var/lib/restic.pass";
    paths = [
      "/var/lib/hass"                 # Home Assistant: config, automations, .storage
      "/var/lib/private/AdGuardHome"  # AdGuard: settings, filters, client config
      "/var/lib/private/ntfy-sh"      # ntfy users/tokens
      "/var/lib/glance.env"           # secrets needed for full restore
      "/var/lib/cloudflared"
      "/var/lib/restic.env"
      "/var/lib/restic.pass"
      "/var/lib/pi-runner/.pi"        # Claude OAuth token + Pi settings
    ];
    timerConfig = { OnCalendar = "03:00"; Persistent = true; };
    pruneOpts = [ "--keep-daily 7" "--keep-weekly 4" "--keep-monthly 6" ];
  };

  # Push an ntfy alert whenever a tagged unit fails
  systemd.services."notify-failure@" = {
    description = "ntfy failure alert for %i";
    serviceConfig.Type = "oneshot";
    scriptArgs = "%i";
    script = ''
      ${pkgs.curl}/bin/curl -s \
        -H "Authorization: Bearer $(cat /var/lib/ntfy-token)" \
        -H "Title: $1 failed on macbook-server" \
        -H "Priority: high" -H "Tags: rotating_light" \
        -d "systemd unit $1 failed — check: journalctl -u $1" \
        http://127.0.0.1:8093/alerts
    '';
  };
  systemd.services."restic-backups-b2".onFailure = [ "notify-failure@restic-backups-b2.service" ];

  # --- Cloudflare Tunnel: keeps ha.stevenjohn.co working ---
  # Dashboard-managed tunnel; token lives in /var/lib/cloudflared/env
  # (TUNNEL_TOKEN=...) — deployed out-of-band, never in git.
  systemd.services.cloudflared-tunnel = {
    description = "Cloudflare Tunnel (stevenjohn.co)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      EnvironmentFile = "/var/lib/cloudflared/env";
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run";
      Restart = "on-failure";
      RestartSec = "5s";
      DynamicUser = true;
    };
  };

  # --- Glance dashboard (web UI :8080) ---
  services.glance = {
    enable = true;
    environmentFile = "/var/lib/glance.env";  # ADGUARD_USERNAME / ADGUARD_PASSWORD
    settings = {
      server = {
        host = "0.0.0.0";
        port = 8080;
      };
      pages = [
        {
          name = "Home";
          columns = [
            {
              size = "small";
              widgets = [
                {
                  type = "monitor";
                  title = "Services";
                  cache = "1m";
                  sites = [
                    { title = "AdGuard Home"; url = "http://192.168.0.40"; icon = "si:adguard"; }
                    { title = "Home Assistant"; url = "https://ha.stevenjohn.co"; icon = "si:homeassistant"; }
                    { title = "ntfy"; url = "https://ntfy.stevenjohn.co"; icon = "si:ntfy"; }
                  ];
                }
              ];
            }
            {
              size = "full";
              widgets = [
                {
                  type = "server-stats";
                  servers = [ { type = "local"; name = "macbook-server"; } ];
                }
                {
                  type = "custom-api";
                  title = "Temps";
                  url = "http://localhost:8090";
                  cache = "1m";
                  template = ''
                    <div class="flex justify-evenly text-center">
                      <div>
                        <div class="color-highlight size-h1">{{ .JSON.Int "battery" }}%</div>
                        <div class="size-h6">BATTERY · {{ .JSON.String "battery_status" }}</div>
                      </div>
                      {{ range .JSON.Array "fans" }}
                      <div>
                        <div class="color-highlight size-h1">{{ .Int "rpm" }}</div>
                        <div class="size-h6">{{ .String "label" }} RPM</div>
                      </div>
                      {{ end }}
                    </div>
                    <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(6.5rem,1fr));gap:.8rem;text-align:center;margin-top:1.4rem;">
                      {{ range .JSON.Array "temps" }}
                      <div>
                        <div class="color-highlight size-h3">{{ .Int "value" }}°</div>
                        <div class="size-h6">{{ .String "label" }}</div>
                      </div>
                      {{ end }}
                    </div>
                  '';
                }
                { type = "clock"; format = "24h"; }
              ];
            }
            {
              size = "small";
              widgets = [
                {
                  type = "dns-stats";
                  service = "adguard";
                  url = "http://localhost:80";
                  username = "\${ADGUARD_USERNAME}";
                  password = "\${ADGUARD_PASSWORD}";
                }
              ];
            }
          ];
        }
      ];
    };
  };

  # --- Tiny temps JSON API (127.0.0.1:8090) for the Glance Temps widget ---
  systemd.services.temps-api = {
    description = "CPU temp + fan RPM JSON endpoint for Glance";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      DynamicUser = true;
      Restart = "on-failure";
      ExecStart = "${pkgs.python3}/bin/python3 ${pkgs.writeText "temps-api.py" ''
        import glob, json
        from http.server import HTTPServer, BaseHTTPRequestHandler

        SMC = "/sys/devices/platform/applesmc.768"
        FRIENDLY = {
            "TB0T": "Battery", "TB1T": "Battery 1", "TB2T": "Battery 2",
            "TC0C": "CPU Core", "TC1C": "CPU Core 1", "TC2C": "CPU Core 2",
            "TC0D": "CPU Die", "TC0E": "CPU Die B", "TC0F": "CPU Die C",
            "TC0P": "CPU Prox", "TCGC": "iGPU", "TCSA": "Sys Agent",
            "TM0P": "Memory", "TP0P": "Platform", "TPCD": "PCH Die",
            "Th1H": "Heatpipe", "Ts0P": "Palm Rest", "Ts0S": "Palm Rest 2",
            "TW0P": "WiFi",
        }

        def read(p):
            try:
                with open(p) as f:
                    return f.read().strip()
            except Exception:
                return None

        def stats():
            temps = []
            for d in glob.glob("/sys/class/hwmon/hwmon*"):
                if read(d + "/name") == "coretemp":
                    for f in sorted(glob.glob(d + "/temp*_input")):
                        v = read(f)
                        if not v:
                            continue
                        lbl = read(f.replace("_input", "_label")) or "CPU"
                        lbl = lbl.replace("Package id 0", "CPU Pkg")
                        temps.append({"label": lbl, "value": int(v) // 1000})
            for f in sorted(glob.glob(SMC + "/temp*_input")):
                v = read(f)
                if v is None:
                    continue
                c = int(v) / 1000
                if c < 5 or c >= 110:
                    continue  # dead/absent sensors (TW0P=-127, TCTD=0, TC0J=~1)
                key = (read(f.replace("_input", "_label")) or "?").strip()
                temps.append({"label": FRIENDLY.get(key, key), "value": round(c)})
            temps.sort(key=lambda t: -t["value"])
            fans = []
            for f in sorted(glob.glob(SMC + "/fan*_input")):
                v = read(f)
                if not v:
                    continue
                lbl = (read(f.replace("_input", "_label")) or "Fan").strip()
                fans.append({"label": lbl, "rpm": int(v)})
            bat = read("/sys/class/power_supply/BAT0/capacity")
            status = read("/sys/class/power_supply/BAT0/status") or ""
            return {
                "battery": int(bat) if bat else 0,
                "battery_status": status,
                "temps": temps,
                "fans": fans,
            }

        class H(BaseHTTPRequestHandler):
            def do_GET(self):
                b = json.dumps(stats()).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def log_message(self, *a):
                pass

        HTTPServer(("127.0.0.1", 8090), H).serve_forever()
      ''}";
    };
  };

  # --- pi-runner: headless homelab-ops agent (127.0.0.1:8091) ---
  # Runs Pi (@earendil-works/pi-coding-agent) non-interactively using the
  # Claude Pro/Max OAuth token in /var/lib/pi-runner/.pi/agent/auth.json
  # (written once via `pi /login anthropic` on the server) + the
  # @gotgenes/pi-anthropic-auth extension. No API key. Only orchestration runs
  # here — model inference is on Anthropic's servers, so the i5 is not taxed.
  users.users.pi-runner = {
    isSystemUser = true;
    group = "pi-runner";
    home = "/var/lib/pi-runner";
    createHome = true;
  };
  users.groups.pi-runner = { };

  systemd.services.pi-runner = {
    description = "Headless Pi homelab-ops agent runner";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    path = [ pkgs.nodejs_22 pkgs.git pkgs.bash pkgs.coreutils ];
    environment = {
      HOME = "/var/lib/pi-runner";
      PI_RUNNER_PORT = "8091";
      PI_MODEL = "claude-sonnet-4-6";
      # npm writes caches under HOME; keep it self-contained
      npm_config_cache = "/var/lib/pi-runner/.npm";
    };
    # Pin versions; install into the state dir on (re)start if missing/outdated.
    preStart = ''
      cd /var/lib/pi-runner
      if [ ! -x node_modules/.bin/pi ] || \
         [ "$(${pkgs.nodejs_22}/bin/node -e 'try{process.stdout.write(require("./node_modules/@earendil-works/pi-coding-agent/package.json").version)}catch(e){process.stdout.write("none")}')" != "0.80.6" ]; then
        echo "pi-runner: installing pinned pi + auth extension…"
        ${pkgs.nodejs_22}/bin/npm install --no-fund --no-audit \
          @earendil-works/pi-coding-agent@0.80.6 \
          @gotgenes/pi-anthropic-auth@1.0.0
      fi
      # Register the OAuth-compat extension in Pi's settings (idempotent).
      mkdir -p .pi/agent
      ${pkgs.nodejs_22}/bin/node -e '
        const fs=require("fs"),p=".pi/agent/settings.json";
        let s={};try{s=JSON.parse(fs.readFileSync(p))}catch{}
        s.packages=Array.from(new Set([...(s.packages||[]),"npm:@gotgenes/pi-anthropic-auth"]));
        s.defaultProvider="anthropic";s.defaultModel="claude-sonnet-4-6";
        fs.writeFileSync(p,JSON.stringify(s,null,2));
      '
      # Install homelab tool extensions (ntfy, etc.) into Pi's extension dir.
      mkdir -p .pi/agent/extensions
      cp -f ${./pi-extensions/ntfy.ts} .pi/agent/extensions/ntfy.ts
    '';
    serviceConfig = {
      User = "pi-runner";
      Group = "pi-runner";
      WorkingDirectory = "/var/lib/pi-runner";
      ExecStart = "${pkgs.nodejs_22}/bin/node ${pkgs.writeText "pi-runner.mjs" (builtins.readFile ./pi-runner.mjs)}";
      Restart = "on-failure";
      RestartSec = "10s";
      # Make the root-only ntfy token readable by this service at
      # $CREDENTIALS_DIRECTORY/ntfy-token (pi-runner.mjs loads it and passes
      # NTFY_TOKEN into the spawned Pi so the ntfy tool can push).
      LoadCredential = [ "ntfy-token:/var/lib/ntfy-token" ];
    };
  };

  # --- Firewall ---
  networking.firewall = {
    allowedTCPPorts = [ 22 53 80 8080 8123 ];  # 80 = AdGuard web UI
    allowedUDPPorts = [ 53 ];
    trustedInterfaces = [ "tailscale0" ];
  };

  users.users.steven = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "changeme";   # change with `passwd` after first login!
  };

  # Passwordless sudo for the wheel group (LAN/Tailscale-only box, key auth).
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [ git vim htop ];

  system.stateVersion = "24.05";
}
