{config, ...}: let
  constants = config.flake.constants;
  healthFlags = config.flake.healthFlags;
  proxyIp = "10.89.0.25";
  vhost = config.flake.pangolinVirtualHosts."needle";
  traefikLabels = config.flake.sorbetTraefikLabels "needle" vhost;
  dataDir = "/var/lib/droppedneedle";
in {
  flake = {
    podmanProxyHosts.needle.ip = proxyIp;

    pangolinVirtualHosts."needle" = {
      site = "sorbet";
      name = "DroppedNeedle";
      subdomain = "needle.int.kuipr.de";
      hostname = "needle";
      port = 8688;
      healthcheck.path = "/health";
    };

    nixosModules.droppedneedle = {config, ...}: {
      virtualisation.oci-containers.containers.needle = {
        labels = traefikLabels;
        image = "ghcr.io/droppedneedle/droppedneedle:latest@sha256:38d702f5ef14fa8c3f028e916011e1fe93a8a2b10452c72e2f6f27e3031356ef";
        volumes = [
          "${dataDir}/config:/app/config"
          "${dataDir}/cache:/app/cache"
          "${dataDir}/plugins:/app/plugins"
          "${dataDir}/imports:/app/imports"
          # one parent for library and completions: imports move instead of copy
          "/media/data:/data"
        ];
        environment = {
          TZ = "Europe/Berlin";
          PUID = "1000";
          PGID = "100";
          UMASK = "002";
          PORT = "8688";
          SLSKD_DOWNLOADS_PATH = "/data/slskd/complete";
          TRUSTED_PROXY_IPS = "${constants.proxyGateway}/32";
        };
        extraOptions =
          [
            "--network=proxy:ip=${proxyIp}"
          ]
          ++ healthFlags {
            cmd = "curl -fsS http://127.0.0.1:8688/health";
            startPeriod = "2m";
            timeout = "15s";
          };
      };

      systemd.tmpfiles.rules = [
        "d ${dataDir}/config 0755 daniel users - -"
        "d ${dataDir}/cache 0755 daniel users - -"
        "d ${dataDir}/plugins 0755 daniel users - -"
        "d ${dataDir}/imports 0755 daniel users - -"
        "d /media/data/slskd/complete 0775 daniel music - -"
      ];
    };
  };
}
