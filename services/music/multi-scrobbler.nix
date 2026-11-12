{config, ...}: let
  proxyIp = "10.89.0.22";
  vhost = config.flake.pangolinVirtualHosts."scrobble";
  traefikLabels = {
    "traefik.enable" = "true";
    "traefik.http.routers.scrobble.rule" = "Host(`${vhost.subdomain}`)";
    "traefik.http.routers.scrobble.entrypoints" = "websecure";
    "traefik.http.routers.scrobble.tls.certresolver" = "letsencrypt";
    "traefik.http.routers.scrobble.service" = "scrobble";
    "traefik.http.routers.scrobble.middlewares" = "sec-headers@file,oidc-auth@file";
    "traefik.http.services.scrobble.loadbalancer.server.port" = toString vhost.port;
    "traefik.http.routers.scrobble-bypass-0.rule" = "Host(`${vhost.subdomain}`) && Path(`/api/version`)";
    "traefik.http.routers.scrobble-bypass-0.entrypoints" = "websecure";
    "traefik.http.routers.scrobble-bypass-0.tls.certresolver" = "letsencrypt";
    "traefik.http.routers.scrobble-bypass-0.service" = "scrobble";
    "traefik.http.routers.scrobble-bypass-0.priority" = "1000";
    "traefik.http.routers.scrobble-bypass-0.middlewares" = "sec-headers@file";
  };
in {
  flake = {
    podmanProxyHosts.multi-scrobbler.ip = proxyIp;

    pangolinVirtualHosts."scrobble" = {
      site = "sorbet";
      name = "Multi-scrobbler";
      subdomain = "scrobble.int.kuipr.de";
      hostname = "multi-scrobbler";
      port = 9078;
      healthcheck.path = "/api/version";
      auth = {
        enable = true;
        bypassPaths = ["/api/version"];
      };
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
        labels = traefikLabels;
        image = "ghcr.io/foxxmd/multi-scrobbler:latest@sha256:d3dacd94c5e6629d9a01579c2e4484de9440c1755dcbaae2ffb50d19b18793a0";
        volumes = [
          "multi-scrobbler-config:/config"
          "${config.sops.secrets."multi-scrobbler/config".path}:/config/config.json:ro"
        ];
        environment = {
          TZ = "Europe/Berlin";
          BASE_URL = "https://scrobble.int.kuipr.de";
          NODE_OPTIONS = "--dns-result-order=ipv6first";
        };
        # probe / not /api/health: that answers 500 while any source is down
        # retry: podman's first check fires immediately; pinned IP + --dns keep attribution
        extraOptions = [
          "--health-cmd=curl -fsS --retry 8 --retry-delay 3 --retry-connrefused http://127.0.0.1:9078/ >/dev/null"
          "--health-interval=30s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=2m"
          "--health-timeout=40s"
          "--network=proxy:ip=${proxyIp}"
          "--network=msv6"
          "--dns=192.168.0.85"
        ];
      };
    };
  };
}
