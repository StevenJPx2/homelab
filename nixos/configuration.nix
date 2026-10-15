{ config, pkgs, ... }:
let
  # Pinned nixpkgs-unstable for Home Assistant 2026.9.1, whose bundled
  # music_assistant integration has the schema-65 token-auth config flow
  # (music-assistant-client 1.4.3). The stable channel may lag the HA release,
  # which cannot authenticate to Music Assistant server >= 2.7.
  unstable = import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/e9b9cbecbf6c25ca26c150d78570e6332694a129.tar.gz";
    sha256 = "1fk1dykv1cdcqsqwa0qqnlvs14cy9zymcfryr7clk5idfdqx7p7m";
  }) { system = "x86_64-linux"; config.allowUnfree = true; };
  dynacat = pkgs.stdenvNoCC.mkDerivation {
    pname = "dynacat";
    version = "3.0.0";
    src = pkgs.fetchurl {
      url = "https://github.com/Panonim/dynacat/releases/download/3.0.0/dynacat-linux-amd64.tar.gz";
      hash = "sha256-NMq8qD8sK/pn2v97OrUyv2pGfz7J6+RahPir9FTjIHY=";
    };
    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      tar -xzf "$src"
      install -Dm755 dynacat $out/bin/dynacat
    '';
  };
in
{
  imports = [ ./hardware-configuration.nix ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelParams = [ "consoleblank=60" ];  # blank screen after 60s

  networking.hostName = "macbook-server";

  # --- Headless laptop behavior ---
  services.logind.settings.Login = {
    HandleLidSwitch = "ignore";
    HandleLidSwitchExternalPower = "ignore";
  };
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

  # --- USB storage / SMB share ---
  fileSystems."/srv/storage" = {
    device = "/dev/disk/by-uuid/6A82-7BC8";
    fsType = "exfat";
    options = [ "nofail" "uid=steven" "gid=users" "umask=0007" ];
  };

  services.samba = {
    enable = true;
    openFirewall = true;
    settings = {
      global = {
        "workgroup" = "WORKGROUP";
        "server string" = "macbook-server";
        "security" = "user";
        "map to guest" = "Never";
      };
      storage = {
        path = "/srv/storage";
        "read only" = "no";
        "browseable" = "yes";
        "valid users" = "steven";
      };
    };
  };

  # Filestash browser-based access to the same storage (files.stjhn.xyz).
  virtualisation.oci-containers.containers.filestash = {
    # Current stable amd64 manifest verified on 2026-09-08.
    image = "machines/filestash@sha256:979cba96df2ed59dab708e4b2c577b9e50947caa823ebfa35befbda7d83331c0";
    environment.APPLICATION_URL = "files.stjhn.xyz";
    ports = [ "8081:8334" ];
    volumes = [
      "/var/lib/filestash:/app/data/state"
      "/srv/storage:/mnt"
    ];
  };

  # --- AdGuard Home (DNS :53, web UI :80 — chosen in setup wizard) ---
  services.adguardhome = {
    enable = true;
    openFirewall = false;  # wizard moved UI to :80; opened explicitly below
  };

  # BlueZ stack for HA's bluetooth integration — hci0 exists but scanner
  # error-spams ("Failed to force stop scanner") without bluetooth.service.
  hardware.bluetooth.enable = true;
  # HA's BLE passive scanning needs bluez experimental features (>= 5.56)
  hardware.bluetooth.settings = {
    General = { Experimental = true; };
  };


  # --- Home Assistant (web UI :8123) ---
  # extraComponents list = official NixOS wiki onboarding set
  services.home-assistant = {
    enable = true;
    package = unstable.home-assistant;
    # Direct-LAN control for the battens. The Tuya CLOUD integration is gone
    # entirely: every batten is driven over tuya_local on the LAN, which drops
    # cloud latency/rate-limit/reverts and makes the cloud's duplicate entities
    # (and its four app scenes) unnecessary.
    # tuya_local's generic A60 CCT profile hardcodes a 2700K warm limit, but
    # these battens natively reach 2000K (as the Tuya cloud exposed). Patch the
    # color_temp floor back to 2000K so warm scenes/buttons aren't clamped.
    customComponents = [
      (unstable.home-assistant-custom-components.tuya_local.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace custom_components/tuya_local/devices/cct_lightbulb.yaml \
            --replace-fail 'min: 2700' 'min: 2000'
        '';
      }))
    ];
    extraComponents = [
      "analytics"
      "google_translate"
      "met"             # weather, required by onboarding
      "radio_browser"
      "shopping_list"
      "isal"            # fast zlib compression
      "esphome"
      "bluetooth"
      "kodi"
      "heos"
      "denonavr"
      "androidtv_remote"
      "apple_tv"
      "upnp"
      "cast"
      "mcp_server"      # Model Context Protocol server (/api/mcp)
      "music_assistant" # bundles music-assistant-client (schema-65 token auth)
    ];
    config = {
      # https://www.home-assistant.io/integrations/default_config/
      default_config = {};
      http = {
        server_host = "0.0.0.0";
        server_port = 8123;
        # cloudflared (ha.stjhn.xyz) runs on this same host
        use_x_forwarded_for = true;
        trusted_proxies = [ "127.0.0.1" "::1" ];
      };
      # Migrated from the old docker setup — UI-editable automations
      "automation ui" = "!include automations.yaml";
      "script ui" = "!include scripts.yaml";
      # The timed hallway automations call this script with their target
      # brightness and temperature. An area-wide light.turn_on can return even
      # when one WiFi batten misses the command; the resync automation cannot
      # infer the scheduled target from the two observed states. Check each
      # local device against the requested values and retry only the laggard.
      "script manual" = let
        battens = [ "light.hallway_batten_local" "light.dining_hall_batten_local" ];
        needsOn = entity: ''
          {{ not is_state('${entity}', 'on')
             or ((state_attr('${entity}', 'brightness') | int(0)
                  - (brightness_pct | float(0) * 255 / 100)) | abs) > 5
             or ((state_attr('${entity}', 'color_temp_kelvin') | int(0)
                  - (color_temp_kelvin | int(0))) | abs) > 100 }}
        '';
      in {
        hallway_schedule = {
          alias = "Hallway schedule (verified local battens)";
          mode = "restart";
          sequence = [{
            repeat = {
              count = 3;
              sequence = [
                {
                  "if" = [{
                    condition = "template";
                    value_template = "{{ brightness_pct | int(0) > 0 }}";
                  }];
                  "then" = builtins.map (entity: {
                    "if" = [{ condition = "template"; value_template = needsOn entity; }];
                    "then" = [{
                      action = "light.turn_on";
                      target.entity_id = entity;
                      data = {
                        brightness_pct = "{{ brightness_pct }}";
                        color_temp_kelvin = "{{ color_temp_kelvin }}";
                      };
                      continue_on_error = true;
                    }];
                  }) battens;
                  "else" = builtins.map (entity: {
                    "if" = [{ condition = "state"; entity_id = entity; state = "on"; }];
                    "then" = [{
                      action = "light.turn_off";
                      target.entity_id = entity;
                      continue_on_error = true;
                    }];
                  }) battens;
                }
                { delay.seconds = 2; }
              ];
            };
          }];
        };
      };
      "scene ui" = "!include scenes.yaml";
      # Stream Deck press-to-ramp brightness (single Short Press toggles a
      # timed ramp; the Elgato HA plugin has no key-down/key-up, so a physical
      # hold is impossible — press once to start, press again to stop).
      input_boolean = {
        sd_bedroom_brighten = {
          name = "Stream Deck Bedroom Brighten Active";
          icon = "mdi:brightness-7";
        };
        sd_bedroom_dim = {
          name = "Stream Deck Bedroom Dim Active";
          icon = "mdi:brightness-3";
        };
      };
      "automation manual" = [
        {
          id = "sd_bedroom_brighten_loop";
          alias = "Stream Deck: Bedroom Brighten Ramp";
          mode = "restart";
          triggers = [{
            trigger = "state";
            entity_id = "input_boolean.sd_bedroom_brighten";
            to = "on";
          }];
          actions = [
            # Stop the opposite ramp if it's running.
            {
              action = "input_boolean.turn_off";
              target.entity_id = "input_boolean.sd_bedroom_dim";
            }
            # If the light is off (e.g. dimmed fully off), seed it on at minimum
            # brightness so the ramp has a non-null level to build from.
            {
              "if" = [{
                condition = "state";
                entity_id = "light.bedroom_ambient";
                state = "off";
              }];
              "then" = [
                {
                  action = "light.turn_on";
                  target.entity_id = "light.bedroom_ambient";
                  data.brightness_pct = 1;
                }
                # Let the seeded brightness settle so the ramp guard below reads
                # a real value instead of the stale null from the off state.
                { delay.milliseconds = 300; }
              ];
            }
            # Logarithmic ramp: each step multiplies brightness by 1.08 (at
            # least +1) so every step looks like the same change to the eye;
            # equal linear steps were invisible in the middle of the range.
            # The level is tracked here rather than re-read from the light, so
            # a lagging state report can't stall or jitter the ramp.
            {
              variables.level = "{{ state_attr('light.bedroom_ambient', 'brightness') | int(3) }}";
            }
            {
              repeat = {
                "while" = [
                  {
                    condition = "state";
                    entity_id = "input_boolean.sd_bedroom_brighten";
                    state = "on";
                  }
                  # ramp all the way to full brightness
                  { condition = "template"; value_template = "{{ level | int < 255 }}"; }
                ];
                sequence = [
                  {
                    variables.level = "{{ [[level | int + 1, (level | int * 1.08) | round(0, 'ceil') | int] | max, 255] | min }}";
                  }
                  {
                    action = "light.turn_on";
                    target.entity_id = "light.bedroom_ambient";
                    data.brightness = "{{ level }}";
                  }
                  { delay.milliseconds = 150; }
                ];
              };
            }
            # Ramp finished (hit ceiling) — reset the button state.
            {
              action = "input_boolean.turn_off";
              target.entity_id = "input_boolean.sd_bedroom_brighten";
            }
          ];
        }
        {
          id = "sd_bedroom_dim_loop";
          alias = "Stream Deck: Bedroom Dim Ramp";
          mode = "restart";
          triggers = [{
            trigger = "state";
            entity_id = "input_boolean.sd_bedroom_dim";
            to = "on";
          }];
          actions = [
            # Stop the opposite ramp if it's running.
            {
              action = "input_boolean.turn_off";
              target.entity_id = "input_boolean.sd_bedroom_brighten";
            }
            # Logarithmic ramp, the mirror of brighten: divide by 1.08 per step.
            {
              variables.level = "{{ state_attr('light.bedroom_ambient', 'brightness') | int(0) }}";
            }
            {
              repeat = {
                "while" = [
                  {
                    condition = "state";
                    entity_id = "input_boolean.sd_bedroom_dim";
                    state = "on";
                  }
                  # ramp to the dimmest step, then turn fully off
                  { condition = "template"; value_template = "{{ level | int > 3 }}"; }
                ];
                sequence = [
                  {
                    variables.level = "{{ [[level | int - 1, (level | int / 1.08) | round(0, 'floor') | int] | min, 3] | max }}";
                  }
                  {
                    action = "light.turn_on";
                    target.entity_id = "light.bedroom_ambient";
                    data.brightness = "{{ level }}";
                  }
                  { delay.milliseconds = 150; }
                ];
              };
            }
            # If the ramp reached the floor (helper still on, not a user stop),
            # switch the light fully off so dim goes all the way to 0.
            {
              "if" = [{
                condition = "state";
                entity_id = "input_boolean.sd_bedroom_dim";
                state = "on";
              }];
              "then" = [{
                action = "light.turn_off";
                target.entity_id = "light.bedroom_ambient";
              }];
            }
            {
              action = "input_boolean.turn_off";
              target.entity_id = "input_boolean.sd_bedroom_dim";
            }
          ];
        }
      ]
      # Resync flaky tuya_local batten pairs. Each *_ambient group is two
      # independent WiFi devices; a dropped LAN command leaves one member
      # disagreeing with the other. When a room's two battens disagree for 5s,
      # re-assert both to whichever member changed most recently (last user
      # action = intent), copying its brightness + color_temp so they match.
      # ponytail: per-pair automations, not a generic template, because there
      # are only two pairs; generalise if a third pair appears.
      ++ (let
        # Single source of truth for "these two have drifted apart". Used both
        # as the entry condition and as the post-delay bail-out, so the two
        # can never disagree about what counts as in-sync. Brightness and
        # colour temp only count while both are lit, and the tolerances absorb
        # the 1-2 unit jitter tuya_local reports for an unchanged value.
        # state_attr (not states[...].attributes.x) because an off light has
        # no brightness attribute at all, and attribute access on a missing
        # key is Undefined, which | int(0) cannot absorb.
        drift = a: b: ''
          {% set ba = state_attr('${a}','brightness') | int(0) %}
          {% set bb = state_attr('${b}','brightness') | int(0) %}
          {% set ca = state_attr('${a}','color_temp_kelvin') | int(0) %}
          {% set cb = state_attr('${b}','color_temp_kelvin') | int(0) %}
          {% set lit = is_state('${a}','on') and is_state('${b}','on') %}
          {{ is_state('${a}','on') != is_state('${b}','on')
             or (lit and (((ba - bb) | abs) > 5 or ((ca - cb) | abs) > 100)) }}
        '';
        resync = { name, a, b }: {
          id = "resync_${name}";
          alias = "Resync ${name} battens";
          mode = "restart";
          # The attribute triggers are load-bearing, not belt-and-braces: a
          # bare state trigger only fires when the on/off string changes, so
          # dimming one batten and leaving the other never reached us.
          triggers = [
            { trigger = "state"; entity_id = a; to = null; }
            { trigger = "state"; entity_id = b; to = null; }
            { trigger = "state"; entity_id = a; attribute = "brightness"; }
            { trigger = "state"; entity_id = b; attribute = "brightness"; }
            { trigger = "state"; entity_id = a; attribute = "color_temp_kelvin"; }
            { trigger = "state"; entity_id = b; attribute = "color_temp_kelvin"; }
          ];
          # Only act when the pair has actually drifted, held 5s (debounces
          # the normal case where both switch a fraction apart).
          conditions = [{
            condition = "template";
            value_template = drift a b;
          }];
          actions = [
            { delay.seconds = 5; }
            # Bail if they reconciled on their own during the wait.
            {
              condition = "template";
              value_template = drift a b;
            }
            # leader = whichever member changed most recently (= last intent).
            # Must be last_updated, not last_changed: last_changed only moves
            # when the on/off string changes, so a dim-only edit — the case
            # this automation now handles — would leave it stale and pick the
            # wrong member as intent.
            {
              variables.leader =
                "{{ '${a}' if states['${a}'].last_updated >= states['${b}'].last_updated else '${b}' }}";
            }
            {
              "if" = [{
                condition = "template";
                value_template = "{{ is_state(leader,'on') }}";
              }];
              "then" = [{
                action = "light.turn_on";
                target.entity_id = [ a b ];
                data = {
                  brightness = "{{ state_attr(leader,'brightness') }}";
                  color_temp_kelvin =
                    "{{ state_attr(leader,'color_temp_kelvin') }}";
                };
              }];
              "else" = [{
                action = "light.turn_off";
                target.entity_id = [ a b ];
              }];
            }
          ];
        };
      in [
        (resync {
          name = "bedroom";
          a = "light.bedroom_batten_local";
          b = "light.bedroom_batten_2_local";
        })
        (resync {
          name = "hallway";
          a = "light.hallway_batten_local";
          b = "light.dining_hall_batten_local";
        })
      ]);
    };
  };

  # Ensure the include files exist so HA doesn't fail on first start
  systemd.tmpfiles.rules = [
    "f /var/lib/hass/automations.yaml 0644 hass hass"
    "f /var/lib/hass/scripts.yaml 0644 hass hass"
    "f /var/lib/hass/scenes.yaml 0644 hass hass"
    # --- lstng rental app --- data dirs (root-owned; containers run as root)
    "d /var/lib/lstng 0755 root root"
    "d /var/lib/lstng/data 0755 root root"
    "d /var/lib/lstng/data/scrape-logs 0755 root root"
    "d /var/lib/lstng/codex 0700 root root"
    "d /var/lib/lstng/images 0755 root root"
    "d /var/lib/filestash 0755 1000 1000"
    "d /var/lib/filestash/log 0755 1000 1000"
    "z /var/lib/filestash 0755 1000 1000"
    "d /var/lib/music-assistant 0755 root root"
    "d /var/lib/dynacat 0750 dynacat dynacat"
    "d /var/lib/dynacat/assets 0750 dynacat dynacat"
    "d /var/lib/dynacat/cache 0750 dynacat dynacat"
  ];

  # --- ntfy push notifications (ntfy.stjhn.xyz via tunnel, local :8093) ---
  services.ntfy-sh = {
    enable = true;
    settings = {
      base-url = "https://ntfy.stjhn.xyz";
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
      "/var/lib/glance.env"           # dashboard secrets needed for full restore
      "/var/lib/dynacat"              # Dynacat cache and state
      "/var/lib/cloudflared"
      "/var/lib/restic.env"
      "/var/lib/restic.pass"
      "/var/lib/lstng/data"           # lstng: app data + scrape logs/schedules
      "/var/lib/music-assistant"      # Music Assistant library and settings
      "/var/lib/filestash"            # Filestash admin and backend configuration
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

  # --- Nuvio TV: auto-update + AOT-compile on the Living Room Onn 4K Pro ---
  # Daily check of NuvioMedia/NuvioTV's most recent release, including beta
  # pre-releases. If the tag differs from the installed versionName, download the
  # universal APK, install over the top, and AOT-compile with `speed`. Idempotent:
  # same version = no-op.
  #
  # NOTE: moving from a beta back to a lower stable version requires uninstalling
  # the app (Android blocks versionCode downgrades), which clears app data.
  #
  # ONE-TIME SETUP: on the TV enable Settings > System > Developer options >
  # Wireless debugging, then run `systemctl start nuvio-update` once and accept the
  # "Allow debugging?" popup (tick "Always allow"). The adb key persists in the
  # StateDirectory so later timer runs are non-interactive.
  #
  # The device is 32-bit only (no arm64), so the universal APK is used; it is not
  # slower than the armeabi-v7a APK (identical native libs + DEX), just larger.
  # TV IP is pinned — set a DHCP reservation for the Onn or edit NUVIO_TV_ADDR.
  systemd.services.nuvio-update = {
    description = "Update + AOT-compile Nuvio on the Living Room TV";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    onFailure = [ "notify-failure@nuvio-update.service" ];
    environment = {
      NUVIO_TV_ADDR = "192.168.0.84:5555";
      HOME = "/var/lib/nuvio-update";   # stable adb key location across runs
    };
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "nuvio-update";  # /var/lib/nuvio-update, persists the adb key
      ExecStart = pkgs.writeShellScript "nuvio-update" ''
        set -euo pipefail
        adb=${pkgs.android-tools}/bin/adb
        curl=${pkgs.curl}/bin/curl
        jq=${pkgs.jq}/bin/jq
        pkg=com.nuvio.tv

        latest=$("$curl" -fsSL "https://api.github.com/repos/NuvioMedia/NuvioTV/releases?per_page=1" | "$jq" -r '.[0].tag_name')
        [ -n "$latest" ] && [ "$latest" != "null" ] || { echo "could not resolve latest tag"; exit 1; }

        "$adb" start-server
        "$adb" connect "$NUVIO_TV_ADDR"
        state=$("$adb" -s "$NUVIO_TV_ADDR" get-state 2>/dev/null || true)
        if [ "$state" != "device" ]; then
          echo "TV not authorized (state=$state). Accept the adb popup on the TV once."; exit 1
        fi

        installed=$("$adb" -s "$NUVIO_TV_ADDR" shell dumpsys package "$pkg" \
          | grep -m1 versionName= | sed 's/.*versionName=//' | tr -d '\r')
        echo "installed=$installed latest=$latest"
        if [ "$installed" = "$latest" ]; then
          echo "already up to date; nothing to do"; exit 0
        fi

        apk=$(mktemp --suffix=.apk)
        trap 'rm -f "$apk"' EXIT
        "$curl" -fsSL -o "$apk" \
          "https://github.com/NuvioMedia/NuvioTV/releases/download/$latest/app-full-universal-release.apk"
        "$adb" -s "$NUVIO_TV_ADDR" install -r "$apk"

        "$adb" -s "$NUVIO_TV_ADDR" shell cmd package compile -m speed -f "$pkg"
        status=$("$adb" -s "$NUVIO_TV_ADDR" shell dumpsys package dexopt \
          | grep -A2 "\[$pkg\]" | grep -o 'status=[a-z-]*' | head -1)
        echo "compile result: $status"
        [ "$status" = "status=speed" ] || { echo "compile did not reach speed"; exit 1; }
        echo "nuvio updated to $latest and compiled (speed)"
      '';
    };
  };

  systemd.timers.nuvio-update = {
    description = "Daily Nuvio update + compile check";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "04:30"; Persistent = true; RandomizedDelaySec = "30m"; };
  };

  # --- Cloudflare Tunnel: public stjhn.xyz services ---
  # This host is the only connector for the dashboard-managed tunnel. A second
  # connector would interpret localhost on the wrong machine and cause 502s.
  # Token lives in /var/lib/cloudflared/env (TUNNEL_TOKEN=...), out of git.
  systemd.services.cloudflared-tunnel = {
    description = "Cloudflare Tunnel (stjhn.xyz)";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      EnvironmentFile = "/var/lib/cloudflared/env";
      ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate run";
      Restart = "always";
      RestartSec = "10s";
      DynamicUser = true;
    };
  };

  users.users.dynacat = {
    isSystemUser = true;
    group = "dynacat";
    home = "/var/lib/dynacat";
  };
  users.groups.dynacat = { };

  # --- Dynacat dashboard (web UI :8080) ---
  # The existing /var/lib/glance.env is retained so the migration does not
  # require copying or reissuing the dashboard secrets.
  environment.etc."dynacat/dynacat.yml".text = ''
    server:
      host: 0.0.0.0
      port: 8080
      proxied: true
      trusted-proxies:
        - 127.0.0.1/32
        - ::1/128
      assets-path: /var/lib/dynacat/assets
      cache-dir: /var/lib/dynacat/cache
      db-path: /var/lib/dynacat/dynacat.db
      allow-editing: false

    auth:
      secret-key: "''${GLANCE_SECRET_KEY}"
      users:
        steven:
          password-hash: "''${GLANCE_PASSWORD_HASH}"

    pages:
      - name: Home
        dynamic-updates: false
        columns:
          - size: small
            widgets:
              - type: monitor
                title: Services
                cache: 1m
                sites:
                  - title: Dynacat
                    url: http://127.0.0.1:8080/api/healthz
                  - title: AdGuard Home
                    url: http://192.168.0.40
                    icon: si:adguard
                  - title: Filestash
                    url: https://files.stjhn.xyz
                    icon: si:files
                  - title: Home Assistant
                    url: https://ha.stjhn.xyz
                    icon: si:homeassistant
                  - title: Music Assistant
                    url: http://192.168.0.40:8095
                    icon: http://192.168.0.40:8095/favicon.ico
                  - title: ntfy
                    url: https://ntfy.stjhn.xyz
                    icon: si:ntfy
                  - title: lstng
                    url: http://127.0.0.1:47821
                    icon: si:rust

          - size: full
            widgets:
              - type: server-stats
                servers:
                  - type: local
                    name: macbook-server
              - type: custom-api
                title: Temps
                url: http://localhost:8090
                cache: 1m
                template: |
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
              - type: custom-api
                title: Storage
                url: http://localhost:8090
                cache: 1m
                template: |
                  <div class="flex justify-evenly text-center">
                    <div><div class="color-positive size-h2">{{ .JSON.String "storage_free" }}</div><div class="size-h6">FREE</div></div>
                    <div><div class="color-highlight size-h2">{{ .JSON.String "storage_total" }}</div><div class="size-h6">TOTAL</div></div>
                    <div><div class="color-primary size-h2">{{ .JSON.Int "storage_used_pct" }}%</div><div class="size-h6">USED</div></div>
                  </div>
              - type: clock
                hour-format: 24h

          - size: small
            widgets:
              - type: dns-stats
                service: adguard
                url: http://localhost:80
                username: "''${ADGUARD_USERNAME}"
                password: "''${ADGUARD_PASSWORD}"
              - type: custom-api
                title: Workhorse Fleet
                url: https://workhorse-sandbox.stevenjpx2.workers.dev/tickets
                headers:
                  Authorization: "Bearer ''${WORKHORSE_TOKEN}"
                cache: 1m
                template: |
                  {{ $running := 0 }}{{ $errored := 0 }}{{ $parked := 0 }}
                  {{ range .JSON.Array "tickets" }}
                    {{ $s := .String "status" }}
                    {{ if or (eq $s "queued") (eq $s "planning") (eq $s "implementing") (eq $s "ready-for-review") }}{{ $running = add $running 1 }}
                    {{ else if eq $s "errored" }}{{ $errored = add $errored 1 }}
                    {{ else if or (eq $s "in-review") (eq $s "awaiting-input") (eq $s "awaiting-acceptance") }}{{ $parked = add $parked 1 }}{{ end }}
                  {{ end }}
                  <div class="flex justify-evenly text-center margin-bottom-10">
                    <div><div class="color-primary size-h2">{{ $running }}</div><div class="size-h6">RUNNING</div></div>
                    <div><div class="color-highlight size-h2">{{ $parked }}</div><div class="size-h6">PARKED</div></div>
                    <div><div class="{{ if gt $errored 0 }}color-negative{{ else }}color-subdue{{ end }} size-h2">{{ $errored }}</div><div class="size-h6">ERRORED</div></div>
                  </div>
                  <ul class="list list-gap-10 collapsible-container" data-collapse-after="6">
                    {{ range .JSON.Array "tickets" }}
                    <li>
                      <div class="flex items-center gap-7">
                        {{ $s := .String "status" }}
                        {{ if eq $s "done" }}<div class="color-positive">●</div>
                        {{ else if eq $s "errored" }}<div class="color-negative">●</div>
                        {{ else if or (eq $s "in-review") (eq $s "awaiting-input") (eq $s "awaiting-acceptance") }}<div class="color-highlight">●</div>
                        {{ else }}<div class="color-primary">●</div>{{ end }}
                        <a class="size-h4 color-highlight text-truncate" href="https://workhorse-ui.stevenjpx2.workers.dev/tickets/{{ .String "id" }}" target="_blank">{{ .String "title" }}</a>
                        {{ if .Exists "prUrl" }}<a class="size-h6" href="{{ .String "prUrl" }}" target="_blank">PR</a>{{ end }}
                        <div class="size-h6 color-subdue" style="margin-left:auto">{{ $s }}</div>
                      </div>
                    </li>
                    {{ end }}
                  </ul>
  '';

  systemd.services.dynacat = {
    description = "Dynacat dashboard";
    after = [ "network-online.target" "systemd-tmpfiles-setup.service" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "dynacat";
      Group = "dynacat";
      WorkingDirectory = "/var/lib/dynacat";
      EnvironmentFile = "/var/lib/glance.env";
      ExecStart = "${dynacat}/bin/dynacat --config /etc/dynacat/dynacat.yml";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  # --- Tiny temps JSON API (127.0.0.1:8090) for the Dynacat Temps widget ---
  systemd.services.temps-api = {
    description = "CPU temp + fan RPM JSON endpoint for Dynacat";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      DynamicUser = true;
      Restart = "on-failure";
      ExecStart = "${pkgs.python3}/bin/python3 ${pkgs.writeText "temps-api.py" ''
        import glob, json, math, shutil
        from http.server import HTTPServer, BaseHTTPRequestHandler

        SMC = "/sys/devices/platform/applesmc.768"
        STORAGE = "/srv/storage"
        FRIENDLY = {
            "TB0T": "Battery", "TB1T": "Battery 1", "TB2T": "Battery 2",
            "TC0C": "CPU Core", "TC1C": "CPU Core 1", "TC2C": "CPU Core 2",
            "TC0D": "CPU Die", "TC0E": "CPU Die B", "TC0F": "CPU Die C",
            "TC0P": "CPU Prox", "TCGC": "iGPU", "TCSA": "Sys Agent",
            "TM0P": "Memory", "TP0P": "Platform", "TPCD": "PCH Die",
            "Th1H": "Heatpipe", "Ts0P": "Palm Rest", "Ts0S": "Palm Rest 2",
            "TW0P": "WiFi",
        }

        def human_size(value):
            for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
                if value < 1024:
                    return f"{math.ceil(value)} {unit}"
                value /= 1024
            return f"{math.ceil(value)} PiB"

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

            try:
                usage = shutil.disk_usage(STORAGE)
                storage_free = human_size(usage.free)
                storage_total = human_size(usage.total)
                storage_used_pct = math.ceil(usage.used / usage.total * 100)
            except OSError:
                storage_free = "n/a"
                storage_total = "n/a"
                storage_used_pct = 0

            return {
                "battery": int(bat) if bat else 0,
                "battery_status": status,
                "temps": temps,
                "fans": fans,
                "storage_free": storage_free,
                "storage_total": storage_total,
                "storage_used_pct": storage_used_pct,
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

  # --- lstng rental app ---------------------------------------------------
  # One-container stack: the Rust API serves the generated static frontend and
  # owns the AI runtime, search, scrapes, schedules, and SSE endpoints.
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # --- Music Assistant (web UI :8095, stream server :8097) -----------------
  # Host networking is required for mDNS/UPnP player discovery and playback.
  # Pinned to 2.10.2: needs HA's schema-65 client (unstable HA above) to pair.
  virtualisation.oci-containers.containers.music-assistant = {
    image = "ghcr.io/music-assistant/server:2.10.2";
    volumes = [ "/var/lib/music-assistant:/data" ];
    extraOptions = [ "--network=host" ];
  };

  # PO-token generator for the YouTube Music provider (bgutil, pinned 2.0.0).
  # MA reaches it at http://127.0.0.1:4416; loopback-only, no host networking.
  virtualisation.oci-containers.containers.bgutil-pot = {
    image = "brainicism/bgutil-ytdlp-pot-provider:2.0.0";
    ports = [ "127.0.0.1:4416:4416" ];
  };

  # The backend listens on 8080; publish the pod through the existing tunnel.
  # A single pod remains necessary because AdGuard owns udp/53 on this host.
  systemd.services.init-lstng-pod = {
    description = "Create the lstng podman pod";
    after = [ "network-online.target" "podman.service" ];
    wants = [ "network-online.target" ];
    before = [ "podman-lstng-backend.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if ${pkgs.podman}/bin/podman pod exists lstng; then
        bindings=$(${pkgs.podman}/bin/podman pod inspect lstng --format '{{json .InfraConfig.PortBindings}}')
        recreate=0
        case "$bindings" in *'"8080/tcp"'*) ;; *) recreate=1 ;; esac
        case "$bindings" in *'"HostPort":"47821"'*) ;; *) recreate=1 ;; esac
        if [ "$recreate" -eq 1 ]; then
          ${pkgs.podman}/bin/podman pod rm -f lstng
        fi
      fi
      ${pkgs.podman}/bin/podman pod exists lstng || \
        ${pkgs.podman}/bin/podman pod create --name lstng -p 127.0.0.1:47821:8080
    '';
  };

  systemd.services.lstng-load-images = {
    description = "Load the transferred lstng backend image";
    after = [ "init-lstng-pod.service" ];
    requires = [ "init-lstng-pod.service" ];
    before = [ "podman-lstng-backend.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.podman}/bin/podman image exists lstng-backend:amd64 || \
        ${pkgs.podman}/bin/podman load -i /var/lib/lstng/images/backend-amd64.tar.gz
    '';
  };

  virtualisation.oci-containers.containers.lstng-backend = {
    image = "lstng-backend:amd64";
    environment = {
      LISTINGS_DB = "/app/data/listings.db";
      SCRAPE_LOG_DIR = "/app/data/scrape-logs";
      SCRAPE_SCHEDULES_FILE = "/app/data/scrape-schedules.json";
      MALLOC_ARENA_MAX = "1";
      CHAT_PROVIDER = "codex";
      CHAT_MODEL = "gpt-5.6-luna";
      CODEX_AUTH_FILE = "/root/.codex/auth.json";
    };
    volumes = [
      "/var/lib/lstng/data:/app/data"
      "/var/lib/lstng/codex:/root/.codex"
    ];
    extraOptions = [ "--pod=lstng" ];
  };
  # --- end lstng rental app -----------------------------------------------

  # --- Firewall ---
  networking.firewall = {
    allowedTCPPorts = [ 22 53 80 8080 8081 8091 8095 8097 8123 ];  # 80 = AdGuard UI, 8091 = agent tickets
    allowedUDPPorts = [ 53 ];
    trustedInterfaces = [ "tailscale0" ];
    # Music Assistant discovers HEOS/DLNA/Chromecast/AirPlay players via SSDP
    # and mDNS multicast. The devices reply with unicast UDP from :1900/:5353
    # to an ephemeral port, which conntrack does not associate with the
    # outgoing multicast, so the stateful firewall drops it. Accept UDP from
    # the trusted LAN /24 so those discovery replies get through.
    extraCommands = ''
      iptables -I nixos-fw 1 -s 192.168.0.0/24 -p udp -j nixos-fw-accept
    '';
  };

  users.users.steven = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "changeme";   # change with `passwd` after first login!
  };

  # Passwordless sudo for the wheel group (LAN/Tailscale-only box, key auth).
  security.sudo.wheelNeedsPassword = false;

  environment.systemPackages = with pkgs; [ git vim htop android-tools ];

  system.stateVersion = "24.05";
}
