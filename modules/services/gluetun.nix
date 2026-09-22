_: {
  flake = {
    nixosModules.gluetun = {lib, ...}: {
      sops.secrets = {
        "gluetun.env" = {
          sopsFile = ../../secrets/sorbet/gluetun.env;
          format = "dotenv";
          key = "";
          restartUnits = ["podman-gluetun.service"];
        };
      };

      systemd = {
        services = {
          podman-create-network-proxy = {
            description = "Create podman proxy network";
            before = ["podman-gluetun.service"];
            wantedBy = ["podman-compose-gluetun-root.target"];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = "/bin/sh -c 'podman network exists proxy || podman network create proxy'";
            };
            path = ["/run/current-system/sw"];
          };

          podman-gluetun = {
            serviceConfig = {
              Restart = lib.mkOverride 90 "always";
            };
            requires = ["podman-create-network-proxy.service"];
            after = ["podman-create-network-proxy.service"];
            partOf = ["podman-compose-gluetun-root.target"];
            wantedBy = ["podman-compose-gluetun-root.target"];
          };
        };

        targets.podman-compose-gluetun-root = {
          unitConfig.Description = "gluetun VPN pod";
          wantedBy = ["multi-user.target"];
        };
      };

      virtualisation.oci-containers = {
        backend = "podman";
        containers = {
          "gluetun" = {
            image = "qmcgaw/gluetun";
            log-driver = "journald";
            environmentFiles = [
              "/run/secrets/gluetun.env"
            ];
            extraOptions = [
              "--cap-add=NET_ADMIN"
              "--device=/dev/net/tun:/dev/net/tun:rwm"
              "--health-cmd=[\"wget\", \"-qO-\", \"https://ipinfo.io/ip\"]"
              "--health-interval=30s"
              "--health-retries=3"
              "--health-start-period=10s"
              "--health-timeout=10s"
              "--network-alias=gluetun"
              "--network=proxy"
            ];
            ports = [
              "8081:8080"
              # slskd web UI: loopback only, so caddy + authelia is the sole way in
              "127.0.0.1:5030:5030"
              "47594/tcp"
              "47594/udp"
            ];
          };
        };
      };
    };
  };
}
