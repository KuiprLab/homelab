_: {
  flake = {
    caddyVirtualHosts."scrobble.int.kuipr.de" = {
      extraConfig = ''
        reverse_proxy localhost:9078
      '';
      name = "Multi Scrobbler";
      authelia = {
        enable = true;
        # gatus probes this vhost sessionless; /api/version bypasses forward
        # auth and is proxied to the app. Deliberately not /api/health — it
        # answers 500 whenever any source/client is down, which would flap
        # this alert on broken (not hung) sources.
        bypassPaths = ["/api/version"];
      };
    };

    gatusEndpoints = [
      {
        name = "Multi-Scrobbler";
        group = "Music";
        url = "https://scrobble.int.kuipr.de/api/version";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
    ];

    nixosModules.multi-scrobbler = {config, ...}: {
      sops.secrets."multi-scrobbler/config" = {
        sopsFile = ../../secrets/sorbet/multi-scrobbler;
        format = "binary";
        key = "";
        owner = "root";
        mode = "0444";
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/multi-scrobbler 0755 root root - -"
      ];

      systemd.services.podman-network-msv6 = {
        description = "Ensure podman msv6 network (IPv6) exists";
        before = ["podman-multi-scrobbler.service"];
        wantedBy = ["podman-multi-scrobbler.service"];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          ${config.virtualisation.podman.package}/bin/podman network exists msv6 || \
            ${config.virtualisation.podman.package}/bin/podman network create --ipv6 msv6
        '';
      };

      virtualisation.oci-containers.containers.multi-scrobbler = {
        image = "ghcr.io/foxxmd/multi-scrobbler:latest@sha256:449274cb8b5b855cc361056862aed6a11e5dcc0a72e2acb279ac78edf834a1c7";
        volumes = [
          "multi-scrobbler-config:/config"
          "${config.sops.secrets."multi-scrobbler/config".path}:/config/config.json:ro"
        ];
        environment = {
          TZ = "Europe/Berlin";
          # Used as base for OAuth redirect URIs (Spotify, Last.fm).
          BASE_URL = "https://scrobble.int.kuipr.de";
          NODE_OPTIONS = "--dns-result-order=ipv6first";
        };
        ports = ["127.0.0.1:9078:9078"];
        # The linuxserver base image ships curl. Probe the UI root — /api/health
        # answers 500 whenever any source/client is down, which would restart-loop
        # on a broken (not hung) source. Retry inside the command: podman's first
        # check fires immediately at start, and a failed transient-unit check
        # aborts NixOS activations. Unhealthy → podman kills → systemd Restart
        # recreates.
        extraOptions = [
          "--health-cmd=curl -fsS --retry 8 --retry-delay 3 --retry-connrefused http://127.0.0.1:9078/ >/dev/null"
          "--health-interval=30s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=2m"
          "--health-timeout=40s"
          "--network=podman"
          "--network=msv6"
        ];
      };
    };
  };
}
