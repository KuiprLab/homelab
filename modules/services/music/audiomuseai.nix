# Audiomuse AI: Redis, PostgreSQL, Flask app, and RQ worker containers
_: {
  flake.nixosModules.audiomuseai = {
    pkgs,
    config,
    lib,
    ...
  }: let
    cfg = config.services.audiomuse;
  in {
    options.services.audiomuse = {
      enable = lib.mkEnableOption "Audiomuse AI service";
      redisPort = lib.mkOption {
        type = lib.types.port;
        default = 6379;
        description = "Port for the Audiomuse Redis instance";
      };
      postgresPort = lib.mkOption {
        type = lib.types.port;
        default = 5432;
        description = "Port for the Audiomuse PostgreSQL instance";
      };
    };

    config = lib.mkMerge [
      {services.audiomuse.enable = lib.mkDefault true;}
      (lib.mkIf cfg.enable {
        virtualisation.oci-containers = {
          backend = "podman";
          containers = {
            audiomuse-redis = {
              image = "redis:7-alpine";
              ports = ["${toString cfg.redisPort}:6379"];
              volumes = ["audiomuse-redis-data:/data"];
            };

            audiomuse-postgres = {
              image = "postgres:15-alpine";
              ports = ["${toString cfg.postgresPort}:5432"];
              environment = {
                POSTGRES_USER = "audiomuse";
                POSTGRES_PASSWORD = "audiomusepassword";
                POSTGRES_DB = "audiomusedb";
              };
              volumes = ["audiomuse-postgres-data:/var/lib/postgresql/data"];
            };

            audiomuse-ai-flask = {
              image = "ghcr.io/neptunehub/audiomuse-ai:latest";
              ports = ["8000:8000"];
              environment = {
                SERVICE_TYPE = "flask";
                TZ = "UTC";
                POSTGRES_USER = "audiomuse";
                POSTGRES_PASSWORD = "audiomusepassword";
                POSTGRES_DB = "audiomusedb";
                POSTGRES_HOST = "audiomuse-postgres";
                POSTGRES_PORT = "5432";
                REDIS_URL = "redis://audiomuse-redis:6379/0";
                TEMP_DIR = "/app/temp_audio";
                AUTH_ENABLED = "false";
              };
              volumes = ["audiomuse-temp-audio-flask:/app/temp_audio"];
            };

            audiomuse-ai-worker = {
              image = "ghcr.io/neptunehub/audiomuse-ai:latest";
              environment = {
                SERVICE_TYPE = "worker";
                TZ = "UTC";
                POSTGRES_USER = "audiomuse";
                POSTGRES_PASSWORD = "audiomusepassword";
                POSTGRES_DB = "audiomusedb";
                POSTGRES_HOST = "audiomuse-postgres";
                POSTGRES_PORT = "5432";
                REDIS_URL = "redis://audiomuse-redis:6379/0";
                TEMP_DIR = "/app/temp_audio";
              };
              volumes = ["audiomuse-temp-audio-worker:/app/temp_audio"];
            };
          };
        };

        systemd.services = {
          "podman-volume-audiomuse-redis-data" = {
            serviceConfig.Type = "oneshot";
            script = "${pkgs.podman}/bin/podman volume create audiomuse-redis-data || true";
            wantedBy = ["multi-user.target"];
          };
          "podman-volume-audiomuse-postgres-data" = {
            serviceConfig.Type = "oneshot";
            script = "${pkgs.podman}/bin/podman volume create audiomuse-postgres-data || true";
            wantedBy = ["multi-user.target"];
          };
          "podman-volume-audiomuse-temp-audio-flask" = {
            serviceConfig.Type = "oneshot";
            script = "${pkgs.podman}/bin/podman volume create audiomuse-temp-audio-flask || true";
            wantedBy = ["multi-user.target"];
          };
          "podman-volume-audiomuse-temp-audio-worker" = {
            serviceConfig.Type = "oneshot";
            script = "${pkgs.podman}/bin/podman volume create audiomuse-temp-audio-worker || true";
            wantedBy = ["multi-user.target"];
          };
        };
      })
    ];
  };
}
