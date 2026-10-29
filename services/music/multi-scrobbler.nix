_: {
  flake = {
    pangolinVirtualHosts."scrobble" = {
      site = "sorbet";
      name = "Multi-scrobbler";
      subdomain = "scrobble.int.kuipr.de";
      port = 9078;
    };

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
        image = "ghcr.io/foxxmd/multi-scrobbler:latest@sha256:74c306b059f6953bc38d69372ca57260b616f2d98502189d32e14caba3c9e419";
        volumes = [
          "multi-scrobbler-config:/config"
          "${config.sops.secrets."multi-scrobbler/config".path}:/config/config.json:ro"
        ];
        environment = {
          TZ = "Europe/Berlin";
          BASE_URL = "https://scrobble.int.kuipr.de";
          NODE_OPTIONS = "--dns-result-order=ipv6first";
        };
        ports = ["127.0.0.1:9078:9078"];
        # probe / not /api/health: that answers 500 while any source is down
        # retry: podman's first check fires immediately; pinned IP + --dns keep attribution
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
