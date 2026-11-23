{config, ...}: let
  constants = config.flake.constants;
  healthFlags = config.flake.healthFlags;
  proxyIp = "10.89.0.24";
  vhost = config.flake.pangolinVirtualHosts."aurral";
  traefikLabels = config.flake.sorbetTraefikLabels "aurral" vhost;
  dataDir = "/media/data/aurral";
  tidarrDownloadsDir = "/media/data/tidarr/config/nzb_downloads";
in {
  flake = {
    podmanProxyHosts.aurral.ip = proxyIp;

    pangolinVirtualHosts."aurral" = {
      site = "sorbet";
      name = "Aurral";
      subdomain = "aurral.int.kuipr.de";
      hostname = "aurral";
      port = 3001;
      healthcheck.path = "/api/health/bootstrap";
    };

    nixosModules.aurral = {config, ...}: {
      sops = {
        # Same value pocketid-provision pushes to Pocket ID, so the two cannot drift.
        secrets."aurral/oidc_client_secret" = {
          sopsFile = ../../secrets/sorbet/pocketid/clients.json;
          format = "json";
          key = "aurral/secret";
        };

        # yt-dlp needs a signed-in YouTube session; the cookie jar stays encrypted at rest.
        secrets."aurral/ytdlp_cookies" = {
          sopsFile = ../../secrets/sorbet/aurral/cookies.txt;
          format = "binary";
          key = "";
          owner = "daniel";
          mode = "0400";
          restartUnits = ["podman-aurral.service"];
        };

        templates."aurral/env" = {
          content = "OIDC_CLIENT_SECRET=${config.sops.placeholder."aurral/oidc_client_secret"}";
          restartUnits = ["podman-aurral.service"];
        };
      };

      virtualisation.oci-containers.containers.aurral = {
        labels = traefikLabels;
        image = "ghcr.io/lklynet/aurral:latest@sha256:17d1f8ff2aaa3907d846c38b47eebdd44b10fbe00b2c993373a6da940ac2504f";
        volumes = [
          "${dataDir}/config:/config"
          # same container path as navidrome, so playlist publishing needs no path mapping
          "/media/data/music:/music"
          "/home/daniel/slskd-downloads:/downloads"
          # Tidarr reports /downloads to SABnzbd clients but stores under /shared/nzb_downloads
          "${tidarrDownloadsDir}:/tidarr-downloads:ro"
          # Path for importing music
          "/home/daniel/music-inbox:/inbox:rw"
          # Outside /config: the entrypoint chowns that tree on start and fails on a read-only file
          "${config.sops.secrets."aurral/ytdlp_cookies".path}:/cookies.txt:ro"
        ];
        environmentFiles = [config.sops.templates."aurral/env".path];
        environment = {
          TZ = "Europe/Berlin";
          PUID = "1000";
          PGID = "100";
          TRUST_PROXY = "true";
          AURRAL_PUBLIC_URL = "https://${vhost.subdomain}";
          LIBRARY_FOLDER = "/music";
          FILE_BROWSE_ROOTS = "/music";
          # Both sources report a container path; map each to the mount above
          PATH_MAPPINGS = "/app/downloads|/downloads;tidarr|/downloads|/tidarr-downloads";
          OIDC_ENABLED = "true";
          OIDC_ISSUER = "https://${constants.idDomain}";
          OIDC_CLIENT_ID = "aurral";
          OIDC_REDIRECT_URI = "https://${vhost.subdomain}/sso/callback";
          OIDC_DOMAIN = "https://${constants.idDomain}";
          OIDC_LOGOUT_URL = "https://${constants.idDomain}/logout";
          OIDC_DEFAULT_ROLE = "user";
          OIDC_ADMIN_USERS = "daniel";
        };
        # the image ships no curl; node is the only HTTP client in it
        extraOptions =
          [
            "--network=proxy:ip=${proxyIp}"
          ]
          ++ healthFlags {
            cmd = ''node -e "fetch('http://127.0.0.1:3001/api/health/bootstrap').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"'';
            startPeriod = "2m";
            timeout = "15s";
          };
      };

      systemd.tmpfiles.rules = [
        "d ${dataDir}/config 0755 daniel users - -"
      ];
    };
  };
}
