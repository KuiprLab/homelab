# Koito — modern, themeable ListenBrainz-compatible scrobbler.
# https://koito.io
_: {
  flake = {
    caddyVirtualHosts = {
      "koito.int.kuipr.de" = {
        extraConfig = ''
          reverse_proxy localhost:4110
        '';
        name = "Koito";
        authelia = {
          enable = true;
          # gatus probes this vhost sessionless; /apis/web/v1/health bypasses
          # forward auth and is proxied to the app (503 until koito is ready).
          bypassPaths = ["/apis/web/v1/health"];
        };
      };
    };

    gatusEndpoints = [
      {
        name = "Koito";
        group = "Music";
        url = "https://koito.int.kuipr.de/apis/web/v1/health";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
    ];

    nixosModules.koito = {config, ...}: {
      sops.secrets = {
        "last-fm-presence" = {
          sopsFile = ../../secrets/sorbet/last-fm-presence.env;
          format = "dotenv";
          key = "";
        };
      };

      virtualisation.oci-containers.containers = {
        koito = {
          image = "docker.io/gabehf/koito:latest@sha256:3011de405ba2a5c56270928c2b0391add8aa3b3ed68363531b3c64b61f238857";
          volumes = [
            "koito-data:/etc/koito"
          ];
          environment = {
            TZ = "Europe/Berlin";
            KOITO_DEFAULT_USERNAME = "daniel";
          };
          ports = ["127.0.0.1:4110:4110"];
          # The bookworm-slim image has no curl/wget — TCP probe via bash's
          # /dev/tcp instead; gatus keeps the real HTTP check via caddy.
          # Unhealthy → podman kills the container; systemd's Restart recreates it.
          #
          # Per-container DNS attribution: aardvark-dns (the default podman DNS
          # proxy) forwards upstream with no client identity, so Pi-hole logs
          # every bridge container as the gateway (10.88.0.1 → FTL shows
          # "host.containers.internal"). Pointing --dns at host dnsmasq makes
          # dnsmasq tag ECS with this container's pinned IP (ip= option), and
          # FTL's dns_hosts table names it. NOTE: this bypasses aardvark, so
          # podman's inter-container name resolution is not available.
          extraOptions = [
            "--health-cmd=bash -c 'exec 3<>/dev/tcp/127.0.0.1/4110'"
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=1m"
            "--health-timeout=5s"
            "--network=podman:ip=10.88.3.22"
            "--dns=192.168.0.85"
          ];
        };

        # No container-level healthcheck: process-only bot, no HTTP endpoint to probe.
        # Pinned IP + --dns: per-container attribution in Pi-hole (see koito above).
        last-fm-presence = {
          image = "ghcr.io/frostplexx/lastfm-discord-presence:main@sha256:0263193924d3010d0775ccb2ecd85d055a959296276634e7aaa16c7c496ffe5f";
          volumes = [];
          environmentFiles = [config.sops.secrets."last-fm-presence".path];
          extraOptions = [
            "--network=podman:ip=10.88.3.23"
            "--dns=192.168.0.85"
          ];
        };
      };
    };
  };
}
