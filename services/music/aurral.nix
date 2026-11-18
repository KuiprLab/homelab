{config, ...}: let
  constants = config.flake.constants;
  healthFlags = config.flake.healthFlags;
  proxyIp = "10.89.0.24";
  vhost = config.flake.pangolinVirtualHosts."aurral";
  traefikLabels = config.flake.sorbetTraefikLabels "aurral" vhost;
  dataDir = "/media/data/aurral";
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
      # Same value pocketid-provision pushes to Pocket ID, so the two cannot drift.
      sops.secrets."aurral/oidc_client_secret" = {
        sopsFile = ../../secrets/sorbet/pocketid/clients.json;
        format = "json";
        key = "aurral/secret";
      };

      sops.templates."aurral/env" = {
        content = "OIDC_CLIENT_SECRET=${config.sops.placeholder."aurral/oidc_client_secret"}";
        restartUnits = ["podman-aurral.service"];
      };

      virtualisation.oci-containers.containers.aurral = {
        labels = traefikLabels;
        # nightly: the plugin API is not in 2.13 yet
        image = "ghcr.io/lklynet/aurral:nightly@sha256:32256d5d1705203172046ad044a4aec3c7e32bb4ea888fbe9b67ff995be6a99a";
        volumes = [
          "${dataDir}/config:/config"
          # same container path as navidrome, so playlist publishing needs no path mapping
          "/media/data/music:/music"
          "/home/daniel/slskd-downloads:/downloads"
          # same path as the deemix container, so its remote paths need no mapping
          "/home/daniel/deemix-downloads:/deemix-downloads"
        ];
        environmentFiles = [config.sops.templates."aurral/env".path];
        environment = {
          TZ = "Europe/Berlin";
          PUID = "1000";
          PGID = "100";
          TRUST_PROXY = "true";
          AURRAL_PUBLIC_URL = "https://${vhost.subdomain}";
          DOWNLOAD_FOLDER = "/music";
          FILE_BROWSE_ROOTS = "/music";
          # slskd reports its own container path; map it to the mount above
          PATH_MAPPINGS = "/app/downloads|/downloads";
          OIDC_ENABLED = "true";
          OIDC_ISSUER = "https://${constants.idDomain}";
          OIDC_CLIENT_ID = "aurral";
          OIDC_REDIRECT_URI = "https://${vhost.subdomain}/sso/callback";
          OIDC_DOMAIN = "https://${constants.idDomain}";
          OIDC_LOGOUT_URL = "https://${constants.idDomain}/logout";
          OIDC_DEFAULT_ROLE = "admin";
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
