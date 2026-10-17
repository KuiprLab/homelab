_: {
  flake = {
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
        image = "ghcr.io/foxxmd/multi-scrobbler:latest@sha256:2a11137663437b5d7c2e24f4d1bfc3ef72ccbeca9e1377e28c72928789236aab";
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
        #
        # Per-container DNS attribution: aardvark-dns (the default podman DNS
        # proxy) forwards upstream with no client identity, so Pi-hole logs
        # every bridge container as the gateway (10.88.0.1 → FTL shows
        # "host.containers.internal"). Pointing --dns at host dnsmasq makes
        # dnsmasq tag ECS with this container's pinned IP (ip= option), and
        # FTL's dns_hosts table names it. NOTE: this bypasses aardvark, so
        # podman's inter-container name resolution is not available.
        extraOptions = [
          "--health-cmd=curl -fsS --retry 8 --retry-delay 3 --retry-connrefused http://127.0.0.1:9078/ >/dev/null"
          "--health-interval=30s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=2m"
          "--health-timeout=40s"
          "--network=podman:ip=10.88.3.21"
          "--network=msv6"
          "--dns=192.168.0.85"
        ];
      };
    };
  };
}
