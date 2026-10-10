# Gatus — synthetic monitoring with Discord alerts.
# Two instances: one on sorbet, one on eclair, cross-probing each other.
#
# Cross-probe topology:
#   sorbet gatus:
#     - LAN/internal services (caddy, navidrome, etc.) on *.int.kuipr.de
#     - Auto-generated *.ext.kuipr.de checks via public DNS → eclair → tailnet
#     - eclair host ICMP + TCP/443
#   eclair gatus:
#     - sorbet caddy via tailnet (tests sorbet from eclair's POV)
#     - ext domains via own loopback haproxy (black-box test of the VPS path)
#     - haproxy stats backend health (catches backend-down even when 443 up)
#
# If sorbet's ISP/host dies, eclair gatus still alerts.
# If eclair dies, sorbet gatus still alerts (and ext checks naturally fail).
{
  lib,
  config,
  ...
}: {
  options.flake = {
    gatusEndpoints = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = ''
        Gatus endpoint configurations contributed by service modules.
        Each entry is an attrset matching the Gatus endpoint schema.
        Consumed by the sorbet-side gatus instance.
      '';
    };

    gatusEclairEndpoints = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = [];
      description = ''
        Endpoints for the eclair-side gatus instance. Kept separate so each
        instance has its own perspective and the two can disagree (which is
        the entire point of cross-probing).
      '';
    };

    gatusExtraConfig = lib.mkOption {
      type = lib.types.attrs;
      default = {};
      description = ''
        Extra top-level Gatus configuration shared by both instances
        (storage, alerting defaults, etc.). Per-instance endpoints are
        merged in by the module builder.
      '';
    };
  };

  config.flake = let
    # eclair public IP — kept in sync with modules/deploy.nix:21.
    # Update both if the VPS gets renumbered.
    eclairPublicIp = "46.38.236.192";

    # Sorbet tailscale IP — also defined in hosts/eclair/default.nix:14.
    # Used by eclair gatus to probe sorbet over tailnet.
    sorbetTailscaleIp = "100.120.32.9";

    # Cert renewal lead time. Bunny DNS-01 renewal usually succeeds well
    # before this; alerting at 7d gives a comfortable window to investigate
    # without waiting for a 24h panic.
    certWarnHours = "168h";

    # .ext vhosts behind authelia SSO, kept in sync with
    # services/music/default.nix. A bare-root probe gets a 302 from
    # authelia and fails [STATUS] == 200, so they are excluded from the
    # auto-generated ext endpoints and monitored by their explicit /healthz
    # endpoint instead.
    ssoProtectedExtHosts = [
      "music.ext.kuipr.de"
      # pi.ext.kuipr.de — authelia SSO; monitored via its /api/auth probe
      # (services/pihole-doh.nix).
      "pi.ext.kuipr.de"
    ];

    # Hosts whose own modules contribute dedicated probes with non-200
    # semantics. The auto-generated probes expect [STATUS] == 200, which
    # these never return on their bare root, so keep them out of both
    # auto lists (they'd false-alert immediately).
    non200ExtHosts = [
      # token-gated DoH: tokenless probe must answer 403 (services/pihole-doh.nix)
      "dns.ext.kuipr.de"
    ];

    extHostNames =
      builtins.filter
      (host: !(lib.elem host (ssoProtectedExtHosts ++ non200ExtHosts)))
      (lib.filter
        (lib.hasSuffix ".ext.kuipr.de")
        (lib.attrNames (config.flake.caddyVirtualHosts // config.flake.eclairCaddyVirtualHosts)));

    # Inject a [RESPONSE_TIME] < 2000 condition into any HTTPS endpoint that
    # doesn't already have one. Without this, a stripe pattern of 5s
    # timeouts can pass the [STATUS] check on alternating probes and never
    # trip the failure-threshold streak. The response-time bound makes
    # every slow probe count as a failure regardless of HTTP outcome.
    #
    # Endpoints that already specify [RESPONSE_TIME] (ext, eclair probes,
    # ICMP/TCP) keep their custom value — only the bare https:// int
    # endpoints get the default.
    hasResponseTimeCond = ep:
      lib.any (c: lib.hasInfix "[RESPONSE_TIME]" c) (ep.conditions or []);

    addDefaultResponseTime = ep:
      if (lib.hasPrefix "https://" (ep.url or "")) && !(hasResponseTimeCond ep)
      then ep // {conditions = ep.conditions ++ ["[RESPONSE_TIME] < 2000"];}
      else ep;

    # Auto-generated external-access endpoints (sorbet POV): one per
    # *.ext.kuipr.de vhost. Exercises the full public path:
    # public DNS → eclair haproxy SNI → tailnet → caddy on sorbet → service.
    extEndpoints =
      map (host: {
        name = "ext: ${host}";
        group = "external";
        url = "https://${host}";
        interval = "60s";
        client.timeout = "10s";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > ${certWarnHours}"
          "[RESPONSE_TIME] < 1500"
        ];
        alerts = [{type = "discord";}];
      })
      extHostNames;

    # Eclair POV: probe each ext host over loopback. Connection goes
    # 127.0.0.1:443 → haproxy (eclair) → tailnet → caddy (sorbet) → service.
    # Black-box tests the haproxy + tailnet legs from inside the VPS.
    # Use --resolve via the URL would be ideal, but gatus relies on the
    # system resolver — so we set client.dns-resolver to point at localhost
    # via /etc/hosts override, OR just hit the public IP and rely on SNI.
    # Simplest: hit https://<host>/ but force resolution to 127.0.0.1 by
    # adding the host to extra-hosts on the gatus container.
    eclairExtLoopbackEndpoints =
      map (host: {
        name = "eclair-loop: ${host}";
        group = "eclair-perspective";
        url = "https://${host}";
        interval = "120s";
        client.timeout = "10s";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > ${certWarnHours}"
          "[RESPONSE_TIME] < 2000"
        ];
        alerts = [{type = "discord";}];
      })
      extHostNames;
  in {
    # ----- sorbet endpoints -----
    gatusEndpoints =
      [
        {
          name = "Caddy";
          # /health bypasses forward auth (see vhost below) — a bare probe
          # would get a 302 from authelia and fail [STATUS] == 200. Note:
          # gatus images >= Oct 2026 no longer serve the /healthz alias.
          url = "https://gatus.int.kuipr.de/health";
          group = "Network";
          conditions = [
            "[STATUS] == 200"
            "[CERTIFICATE_EXPIRATION] > ${certWarnHours}"
          ];
          alerts = [{type = "discord";}];
        }

        # eclair host reachability — ICMP probe to public IP. Catches VPS
        # being down/unreachable independently of haproxy or any backend.
        {
          name = "eclair (ICMP)";
          group = "External";
          url = "icmp://${eclairPublicIp}";
          interval = "60s";
          conditions = [
            "[CONNECTED] == true"
            "[RESPONSE_TIME] < 250"
          ];
          alerts = [{type = "discord";}];
        }

        # eclair haproxy TCP listener — confirms 443 accepts connections.
        # If this is up but ext-* HTTPS checks fail, problem is upstream
        # (tailnet, caddy, or the service itself).
        {
          name = "eclair haproxy (TCP/443)";
          group = "External";
          url = "tcp://${eclairPublicIp}:443";
          interval = "60s";
          conditions = [
            "[CONNECTED] == true"
            "[RESPONSE_TIME] < 1000"
          ];
          alerts = [{type = "discord";}];
        }
      ]
      ++ extEndpoints;

    # ----- eclair endpoints -----
    gatusEclairEndpoints =
      [
        # Sorbet caddy via tailnet — confirms tailnet leg + caddy listener
        # without going through public DNS or haproxy. If this fails but ext
        # checks succeed, eclair routing is fine but tailscale node
        # connectivity is degraded. The probe must use a real Host header
        # caddy serves; gatus.int.kuipr.de is the lightest endpoint.
        {
          name = "sorbet caddy (tailnet)";
          group = "sorbet-perspective";
          # /health bypasses forward auth, same as the sorbet-side Caddy check.
          # gatus images >= Oct 2026 no longer serve the /healthz alias.
          url = "https://gatus.int.kuipr.de/health";
          interval = "60s";
          client = {
            timeout = "10s";
            # Force resolution to sorbet's tailscale IP regardless of public DNS.
            # Achieved via extra-hosts on the container (see module below).
          };
          conditions = [
            "[STATUS] == 200"
            "[CERTIFICATE_EXPIRATION] > ${certWarnHours}"
            "[RESPONSE_TIME] < 1500"
          ];
          alerts = [{type = "discord";}];
        }

        # Beszel hub — direct tailnet probe on the hub's own port, skipping
        # caddy. If the sorbet-side mon.int.kuipr.de check fails but this
        # stays up, the hub is fine and caddy is the problem.
        {
          name = "beszel hub (tailnet)";
          group = "sorbet-perspective";
          url = "http://${sorbetTailscaleIp}:8091/api/health";
          interval = "60s";
          client.timeout = "10s";
          conditions = [
            "[STATUS] == 200"
            "[RESPONSE_TIME] < 1500"
          ];
          alerts = [{type = "discord";}];
        }

        # haproxy stats — backend up/down + active session count.
        # If be_sorbet shows DOWN, alert before users notice 503s.
        # Stats endpoint is on 127.0.0.1:8404 (see haproxy.nix).
        # Container reaches it via host.containers.internal or host network;
        # easiest is host network on the container itself.
        {
          name = "haproxy backend (be_sorbet)";
          group = "Network";
          url = "http://127.0.0.1:8404/stats;csv;norefresh";
          interval = "60s";
          conditions = [
            "[STATUS] == 200"
            # CSV column 18 (status) for the be_sorbet/sorbet row should be UP.
            # Pattern match the substring — gatus has no CSV parser, but
            # the line "be_sorbet,sorbet,...,UP,..." is unambiguous when up.
            "[BODY] == pat(*be_sorbet,sorbet,*UP*)"
          ];
          alerts = [{type = "discord";}];
        }
      ]
      ++ eclairExtLoopbackEndpoints;

    caddyVirtualHosts."gatus.int.kuipr.de" = {
      extraConfig = "reverse_proxy localhost:8888";
      name = "Gatus";
      authelia = {
        enable = true;
        # gatus probes its own dashboard with no session; authelia would 302
        # it. /health answers 200 from caddy, bypassing forward auth.
        # gatus images >= Oct 2026 no longer serve the /healthz alias.
        bypassPaths = ["/health"];
      };
    };

    gatusExtraConfig = {
      storage = {
        type = "sqlite";
        path = "/data/data.db";
      };
      alerting.discord = {
        webhook-url = "$DISCORD_WEBHOOK_URL";
        default-alert = {
          # 2 consecutive failures (~2min at 60s interval) trips the alert.
          # Was 3 — too lenient: a 50/50 stripe pattern of timeouts never
          # produced 3 fails in a row, so flapping went unnoticed.
          failure-threshold = 2;
          success-threshold = 2;
          send-on-resolved = true;
        };
      };
    };

    # ----- sorbet gatus NixOS module -----
    nixosModules.gatus = let
      endpoints = map addDefaultResponseTime config.flake.gatusEndpoints;
      extraConfig = config.flake.gatusExtraConfig;
      gatusConfig =
        extraConfig
        // {
          inherit endpoints;
          web.port = 8888;
          # Identify which instance fired an alert.
          ui.header = "sorbet";
        };
    in
      {
        pkgs,
        config,
        ...
      }: {
        sops.secrets."gatus/discord_webhook" = {
          sopsFile = ../secrets/sorbet/gatus;
          format = "binary";
          key = "";
          owner = "root";
        };

        # No container-level healthcheck: the gatus image is FROM scratch —
        # no shell, wget, or curl to probe with. Availability is covered by
        # eclair's gatus instance and the healthchecks.io heartbeat.
        virtualisation.oci-containers.containers.gatus = {
          image = "ghcr.io/twin/gatus:latest@sha256:49612466499ea56047637776b9974ab91d11c0084a2aa728a16db01e93654952";
          volumes = [
            "${(pkgs.formats.yaml {}).generate "gatus.yaml" gatusConfig}:/config/config.yaml:ro"
            "gatus-data:/data"
          ];
          ports = ["127.0.0.1:8888:8888"];
          environment = {
            TZ = "Europe/Berlin";
          };
          environmentFiles = [config.sops.secrets."gatus/discord_webhook".path];
          # --dns=192.168.0.85: Use host dnsmasq directly. Default podman
          #   DNS path goes through aardvark-dns which inherits the host's
          #   /etc/resolv.conf (nameserver 127.0.0.1) — but 127.0.0.1
          #   inside the container is the container itself, so every
          #   *.int.kuipr.de lookup hung ~5s before failing, producing
          #   striped graphs. 192.168.0.85 is sorbet's LAN IP where
          #   dnsmasq listens with the split-horizon overrides.
          # --cap-add=NET_RAW: Required for icmp:// endpoints. The default
          #   podman cap set drops NET_RAW, so gatus's raw-socket ping
          #   fails instantly (duration=0s, no probe ever runs). Without
          #   this, the eclair (ICMP) check shows N/A response time and
          #   stays Unhealthy regardless of actual reachability.
          extraOptions = [
            "--dns=192.168.0.85"
            "--network=podman:ip=10.88.3.24"
            "--cap-add=NET_RAW"
          ];
        };
      };

    # ----- eclair gatus NixOS module -----
    eclairNixosModules.gatus = let
      endpoints = map addDefaultResponseTime config.flake.gatusEclairEndpoints;
      extraConfig = config.flake.gatusExtraConfig;
      gatusConfig =
        extraConfig
        // {
          inherit endpoints;
          web = {
            address = "127.0.0.1";
            port = 8888;
          };
          ui.header = "eclair";
        };

      # Force *.ext.kuipr.de to resolve to 127.0.0.1 *inside the gatus
      # container only*, so loopback checks traverse the local haproxy
      # instead of going out to the public DNS A record (which would still
      # land on this same machine but adds an unnecessary egress hop).
      loopbackHostExtras =
        map (h: "${h}:127.0.0.1") extHostNames;

      # Force gatus.int.kuipr.de to resolve to sorbet's tailscale IP, so
      # the "sorbet caddy (tailnet)" check goes via tailscale, not DNS.
      sorbetHostExtras = ["gatus.int.kuipr.de:${sorbetTailscaleIp}"];

      extraHostsArgs =
        map (e: "--add-host=${e}") (loopbackHostExtras ++ sorbetHostExtras);
    in
      {
        pkgs,
        config,
        ...
      }: {
        sops.secrets."gatus/discord_webhook" = {
          # Same webhook bytes as sorbet — copy the encrypted file from
          # secrets/sorbet/gatus into secrets/eclair/gatus (single age
          # recipient handles both hosts).
          sopsFile = ../secrets/eclair/gatus;
          format = "binary";
          key = "";
          owner = "root";
        };

        virtualisation = {
          podman.enable = lib.mkDefault true;

          oci-containers = {
            backend = lib.mkDefault "podman";
            # No healthcheck: scratch image, no probe binary (see sorbet gatus).
            containers.gatus = {
              image = "ghcr.io/twin/gatus:latest@sha256:49612466499ea56047637776b9974ab91d11c0084a2aa728a16db01e93654952";
              volumes = [
                "${(pkgs.formats.yaml {}).generate "gatus.yaml" gatusConfig}:/config/config.yaml:ro"
                "gatus-data:/data"
              ];
              # Host network: container reaches haproxy stats on 127.0.0.1:8404
              # and haproxy https on 127.0.0.1:443 directly. Gatus binds to
              # 127.0.0.1:8888 via web.address (see config above) so the
              # dashboard isn't exposed publicly. eclair firewall doesn't open
              # 8888 anyway. SSH-tunnel to view:
              #   ssh -L 8889:127.0.0.1:8888 root@eclair
              # `ports` is intentionally omitted — host network ignores it.
              environment.TZ = "Europe/Berlin";
              environmentFiles = [config.sops.secrets."gatus/discord_webhook".path];
              extraOptions =
                extraHostsArgs
                ++ ["--network=host"];
            };
          };
        };
      };
  };
}
