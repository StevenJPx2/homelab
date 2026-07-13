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
  services.tailscale.enable = true;

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
                    { title = "Home Assistant"; url = "http://192.168.0.40:8123"; icon = "si:homeassistant"; }
                    { title = "HA public (tunnel)"; url = "https://ha.stevenjohn.co"; icon = "si:cloudflare"; }
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

  environment.systemPackages = with pkgs; [ git vim htop ];

  system.stateVersion = "24.05";
}
