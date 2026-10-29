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
          UPSNAP_HTTP_LISTEN = "127.0.0.1:8090";
        };
        image = "ghcr.io/seriousm4x/upsnap:latest@sha256:1e7c2345c493f9228a5dc2102be06b5a33331100f303fe0078502f4ef1068724";
        # Podman does not inherit image HEALTHCHECKs.
        extraOptions = [
          "--health-cmd=curl -fsS --retry 10 --retry-delay 2 --retry-connrefused http://127.0.0.1:8090/api/health >/dev/null"
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
