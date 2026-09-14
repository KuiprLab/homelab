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
        ports = ["8090:8090"];
        environment = {
          TZ = "Europe/Berlin";
          SLSKD_REMOTE_CONFIGURATION = "true";
        };
        image = "ghcr.io/seriousm4x/upsnap:latest";
        labels = {
          "io.containers.autoupdate" = "registry";
        };
        extraOptions = [
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
