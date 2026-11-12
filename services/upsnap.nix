_: {
  flake = {
    pangolinVirtualHosts."up" = {
      site = "sorbet";
      name = "Upsnap";
      subdomain = "up.int.kuipr.de";
      port = 8090;
    };

    nixosModules.upsnap = {pkgs, ...}: {
      virtualisation.oci-containers.containers.upsnap = {
        volumes = [
          "upsnap-data:/app/pb_data"
        ];
        user = "1000:100";
        # Host networking is needed for LAN scanning; the bind address comes from UPSNAP_HTTP_LISTEN.
        environment = {
          TZ = "Europe/Berlin";
          UPSNAP_HTTP_LISTEN = "10.89.0.1:8090";
        };
        image = "ghcr.io/seriousm4x/upsnap:latest@sha256:e01e61ac6bfbf34a2003364e1499faf2da0fba0a485e0f4b31c49b6576b95e9d";
        # Podman does not inherit image HEALTHCHECKs.
        extraOptions = [
          "--health-cmd=curl -fsS --retry 10 --retry-delay 2 --retry-connrefused http://10.89.0.1:8090/api/health >/dev/null"
          "--health-interval=10s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=30s"
          "--health-timeout=30s"
          "--dns=192.168.0.85"
          "--cap-add=NET_RAW"
          "--network=host"
        ];
      };

      # Binds the bridge gateway, so the network must exist first.
      systemd.services."podman-upsnap" = {
        requires = ["podman-create-network-proxy.service"];
        after = ["podman-create-network-proxy.service"];
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
