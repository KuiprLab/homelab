# Koito — modern, themeable ListenBrainz-compatible scrobbler.
# https://koito.io
_: {
  flake = {
    caddyVirtualHosts = {
      "koito.int.kuipr.de" = {
        extraConfig = ''
          reverse_proxy localhost:4110
        '';
        name = "Koito";
        authelia = {
          enable = true;
          # gatus probes this vhost sessionless; /healthz bypasses forward auth.
          bypassPaths = ["/healthz"];
        };
      };
    };

    gatusEndpoints = [
      {
        name = "Koito";
        group = "Music";
        url = "https://koito.int.kuipr.de/healthz";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        alerts = [{type = "discord";}];
      }
    ];

    nixosModules.koito = {config, ...}: {
      sops.secrets = {
        "last-fm-presence" = {
          sopsFile = ../../secrets/sorbet/last-fm-presence.env;
          format = "dotenv";
          key = "";
        };
      };

      virtualisation.oci-containers.containers = {
        koito = {
          image = "docker.io/gabehf/koito:latest";
          volumes = [
            "koito-data:/etc/koito"
          ];
          environment = {
            TZ = "Europe/Berlin";
            KOITO_DEFAULT_USERNAME = "daniel";
          };
          ports = ["127.0.0.1:4110:4110"];
          labels = {
            "io.containers.autoupdate" = "registry";
          };
        };

        last-fm-presence = {
          image = "ghcr.io/frostplexx/lastfm-discord-presence:main";
          volumes = [];
          environmentFiles = [config.sops.secrets."last-fm-presence".path];
          labels = {
            "io.containers.autoupdate" = "registry";
          };
        };
      };
    };
  };
}
