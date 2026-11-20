{config, ...}: let
  proxyIp = "10.89.0.25";
  healthFlags = config.flake.healthFlags;
  vhost = config.flake.pangolinVirtualHosts."tidarr";
  traefikLabels = config.flake.sorbetTraefikLabels "tidarr" vhost;
  dataDir = "/media/data/tidarr";
in {
  flake = {
    podmanProxyHosts.tidarr.ip = proxyIp;

    pangolinVirtualHosts."tidarr" = {
      site = "sorbet";
      name = "Tidarr";
      subdomain = "tidarr.int.kuipr.de";
      hostname = "tidarr";
      port = 8484;
      private = true;
    };

    nixosModules.tidarr = {config, ...}: let
      # pinned UID/GID for tidarr user
      uid = 987;
      gid = 987;
    in {
      users.groups.tidarr.gid = gid;
      users.users.tidarr = {
        isSystemUser = true;
        inherit uid;
        group = "tidarr";
      };



      virtualisation.oci-containers.containers.tidarr = {
        labels = traefikLabels;
        image = "ghcr.io/cstaelen/tidarr:latest";
        volumes = [
          "${dataDir}/config:/shared"
          "/media/data/music:/music"
        ];
        user = "${toString uid}:${toString gid}";
        environment = {
          TZ = "Europe/Berlin";
          PUID = "${toString uid}";
          PGID = "${toString gid}";
          # Optional: set admin password via env or use OIDC
          # ADMIN_PASSWORD = "";
          # OIDC_ISSUER = "https://${config.flake.constants.idDomain}";
          # OIDC_CLIENT_ID = "tidarr";
          # OIDC_REDIRECT_URI = "https://tidarr.int.kuipr.de/api/auth/oidc/callback";
        };
        extraOptions = [
          "--network=proxy:ip=${proxyIp}"
        ] ++ healthFlags {
          cmd = "curl -fsS --retry 3 --retry-delay 2 http://127.0.0.1:8484/api/health >/dev/null";
          startPeriod = "30s";
          timeout = "10s";
        };
      };

      systemd.tmpfiles.rules = [
        "d ${dataDir}/config 0755 ${toString uid} ${toString gid} - -"
      ];
    };
  };
}
