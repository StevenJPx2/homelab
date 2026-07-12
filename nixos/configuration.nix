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

  # --- Syncthing (web UI :8384) ---
  services.syncthing = {
    enable = true;
    user = "steven";
    dataDir = "/home/steven/sync";
    guiAddress = "0.0.0.0:8384";
    openDefaultPorts = true;   # 22000/tcp+udp transfers, 21027/udp discovery
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
                    { title = "Syncthing"; url = "http://192.168.0.40:8384"; icon = "si:syncthing"; }
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
              ];
            }
            {
              size = "small";
              widgets = [
                { type = "clock"; format = "24h"; }
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

  # --- Firewall ---
  networking.firewall = {
    allowedTCPPorts = [ 22 53 80 8080 8123 8384 ];  # 80 = AdGuard web UI
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
