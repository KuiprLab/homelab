_: {
  flake = {
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
            # --health-on-failure=kill: podman kills the container when its
            # healthcheck fails; the systemd unit's Restart=on-failure then
            # recreates it (podman docs warn against `restart` under systemd,
            # which owns all restarts here).
            extraOptions = [
              "--cap-add=NET_ADMIN"
              "--device=/dev/net/tun:/dev/net/tun:rwm"
              # Podman runs each check in a transient systemd unit; a failed unit
              # aborts NixOS activations. The first check fires before the VPN
              # tunnel is up, so retry inside the command until it is established.
              "--health-cmd=sh -c 'n=0; until wget -qO- https://ipinfo.io/ip >/dev/null 2>&1; do n=$((n+1)); [ $n -ge 12 ] && exit 1; sleep 5; done'"
              "--health-interval=30s"
              "--health-on-failure=kill"
              "--health-retries=3"
              "--health-start-period=10s"
              "--health-timeout=90s"
              "--network-alias=gluetun"
              "--network=proxy"
            ];
            ports = [
              "8081:8080"
              # slskd web UI: loopback only, so caddy + authelia is the sole way in
              "127.0.0.1:5030:5030"
              # aiostreams: loopback only, caddy publishes it as *.ext.kuipr.de
              "127.0.0.1:3000:3000"
              "47594/tcp"
              "47594/udp"
            ];
          };
        };
      };
    };
  };
}
