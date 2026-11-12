{config, ...}: let
  proxyIp = "10.89.0.20";
  vhost = config.flake.pangolinVirtualHosts."slskd";
  traefikLabels = {
    "traefik.enable" = "true";
    "traefik.http.routers.slskd.rule" = "Host(`${vhost.subdomain}`)";
    "traefik.http.routers.slskd.entrypoints" = "websecure";
    "traefik.http.routers.slskd.tls.certresolver" = "letsencrypt";
    "traefik.http.routers.slskd.service" = "slskd";
    "traefik.http.routers.slskd.middlewares" = "sec-headers@file,oidc-auth@file";
    "traefik.http.services.slskd.loadbalancer.server.port" = toString vhost.port;
    # slskd keeps its own API auth (/api/*) and health endpoint; both must stay
    # reachable without the login so the app and pangolin's probe work.
    "traefik.http.routers.slskd-bypass-health.rule" = "Host(`${vhost.subdomain}`) && Path(`/health`)";
    "traefik.http.routers.slskd-bypass-health.entrypoints" = "websecure";
    "traefik.http.routers.slskd-bypass-health.tls.certresolver" = "letsencrypt";
    "traefik.http.routers.slskd-bypass-health.service" = "slskd";
    "traefik.http.routers.slskd-bypass-health.priority" = "1000";
    "traefik.http.routers.slskd-bypass-health.middlewares" = "sec-headers@file";
    "traefik.http.routers.slskd-bypass-api.rule" = "Host(`${vhost.subdomain}`) && PathPrefix(`/api/`)";
    "traefik.http.routers.slskd-bypass-api.entrypoints" = "websecure";
    "traefik.http.routers.slskd-bypass-api.tls.certresolver" = "letsencrypt";
    "traefik.http.routers.slskd-bypass-api.service" = "slskd";
    "traefik.http.routers.slskd-bypass-api.priority" = "1000";
    "traefik.http.routers.slskd-bypass-api.middlewares" = "sec-headers@file";
  };
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
            image = "ghcr.io/qdm12/gluetun:latest@sha256:cbafe0945d0fe5a3c55ca64d43a85c5db270458f4c645ee65797b527f6f57a64";
            log-driver = "journald";
            environmentFiles = [
              "/run/secrets/gluetun.env"
            ];
            # podman kills an unhealthy container; systemd's Restart recreates it.
            # podman kills an unhealthy container; systemd's Restart recreates it.
            extraOptions = [
              "--cap-add=NET_ADMIN"
              "--device=/dev/net/tun:/dev/net/tun:rwm"
              "--health-cmd=sh -c 'n=0; until wget -qO- https://ipinfo.io/ip >/dev/null 2>&1; do n=$((n+1)); [ $n -ge 12 ] && exit 1; sleep 5; done'"
              "--health-interval=30s"
              "--health-on-failure=kill"
              "--health-retries=3"
              "--health-start-period=10s"
              "--health-timeout=90s"
              "--network-alias=gluetun"
              # Pinned for a stable identity in the DNS query log.
              "--network=proxy:ip=${proxyIp}"
            ];
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
