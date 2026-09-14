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
      };

      "subtidal.ext.kuipr.de" = {
        extraConfig = ''
          reverse_proxy localhost:4234
        '';
        name = "Subtidal";
      };
    };

    gatusEndpoints = [
      {
        name = "Koito";
        group = "Music";
        url = "https://koito.int.kuipr.de";
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
          sopsFile = ../../../secrets/sorbet/last-fm-presence.env;
          format = "dotenv";
          key = "";
        };
        "subtidal" = {
          sopsFile = ../../../secrets/sorbet/subtidal.toml;
          format = "binary";
          owner = "daniel";
          mode = "755";
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

        subtidal = {
          image = "ghcr.io/frostplexx/subtidal:latest";
          volumes = [
            "/home/daniel/subtidal:/data:rw"
            "${config.sops.secrets."subtidal".path}:/config/subtidal/settings.toml:ro"
          ];
          user = "1000:100";
          ports = ["4234:8000"];
          environment = {
            TZ = "Europe/Berlin";
            XDG_CONFIG_HOME = "/config";
            SUBTIDAL_TOKEN_FILE = "/data/tokens.json";
            RUST_LOG = "info";
          };
          labels = {
            "io.containers.autoupdate" = "registry";
          };
        };
      };
    };
  };
}
