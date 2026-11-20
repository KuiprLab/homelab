{config, ...}: let
  proxyIp = "10.89.0.20";
  healthFlags = config.flake.healthFlags;
  vhost = config.flake.pangolinVirtualHosts."slskd";
  traefikLabels = config.flake.sorbetTraefikLabels "slskd" vhost;
in {
  flake = {
    podmanProxyHosts.gluetun.ip = proxyIp;

    nixosModules.gluetun = {lib, ...}: {
      sops.secrets = {
        "gluetun.env" = {
          sopsFile = ../secrets/sorbet/gluetun.env;
          format = "dotenv";
          key = "";
          restartUnits = ["podman-gluetun.service"];
        };
      };

      systemd = {
        services = {
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
            labels = traefikLabels;
            image = "ghcr.io/qdm12/gluetun:latest@sha256:b68e26d63c1cb352b53518e4f96fbb12eb9ae8412ec0c2bc5c47bca2c1338b9e";
            log-driver = "journald";
            environmentFiles = [
              "/run/secrets/gluetun.env"
            ];
            # podman kills an unhealthy container; systemd's Restart recreates it.
            extraOptions =
              [
                "--cap-add=NET_ADMIN"
                "--device=/dev/net/tun:/dev/net/tun:rwm"
                "--network-alias=gluetun"
                # Pinned for a stable identity in the DNS query log.
                "--network=proxy:ip=${proxyIp}"
              ]
              ++ healthFlags {
                cmd = "sh -c 'n=0; until wget -qO- https://ipinfo.io/ip >/dev/null 2>&1; do n=$((n+1)); [ $n -ge 12 ] && exit 1; sleep 5; done'";
                startPeriod = "10s";
                timeout = "90s";
              };
            ports = [
              "47594/tcp"
              "47594/udp"
            ];
          };
        };
      };
    };
  };
}
