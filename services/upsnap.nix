_: {
  flake = {
    caddyVirtualHosts."up.int.kuipr.de" = {
      extraConfig = ''
        reverse_proxy 127.0.0.1:8090
      '';
      name = "Upsnap";
    };

    nixosModules.upsnap = {pkgs, ...}: {
      virtualisation.oci-containers.containers.upsnap = {
        volumes = [
          "upsnap-data:/app/pb_data"
        ];
        user = "1000:100";
        # --network=host is required for LAN device scanning (ping/TCP checks
        # against 192.168.0.0/24 with NET_RAW). The publish map is ignored
        # under host networking, so the web UI's bind address is controlled
        # via the app's own env: loopback only, caddy is the sole way in.
        environment = {
          TZ = "Europe/Berlin";
          UPSNAP_HTTP_LISTEN = "127.0.0.1:8090";
        };
        image = "ghcr.io/seriousm4x/upsnap:latest@sha256:1e7c2345c493f9228a5dc2102be06b5a33331100f303fe0078502f4ef1068724";
        # Podman does not inherit image HEALTHCHECKs — mirror the upstream
        # one explicitly (curl → 127.0.0.1:8090/api/health).
        # Unhealthy → podman kills the container; systemd's Restart recreates it.
        extraOptions = [
          "--health-cmd=curl -fs http://127.0.0.1:8090/api/health"
          "--health-interval=10s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=30s"
          "--health-timeout=5s"
          "--dns=192.168.0.85"
          "--cap-add=NET_RAW"
          "--network=host"
        ];
      };

      systemd.services = {
        "podman-volume-upsnap-data" = {
          serviceConfig.Type = "oneshot";
          script = "${pkgs.podman}/bin/podman volume create upsnap-data || true";
          wantedBy = ["multi-user.target"];
        };
      };
    };
  };
}
