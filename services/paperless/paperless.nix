{config, ...}: let
  constants = config.flake.constants;
  healthFlags = config.flake.healthFlags;
  proxyIp = "10.89.0.30";
  tikaIp = "10.89.0.31";
  gotenbergIp = "10.89.0.32";
  redisIp = "10.89.0.33";
  vhost = config.flake.pangolinVirtualHosts."paperless";
  traefikLabels = config.flake.sorbetTraefikLabels "paperless" vhost;
in {
  flake = {
    podmanProxyHosts = {
      paperless.ip = proxyIp;
      paperless-tika.ip = tikaIp;
      paperless-gotenberg.ip = gotenbergIp;
      paperless-redis.ip = redisIp;
    };

    pangolinVirtualHosts."paperless" = {
      site = "sorbet";
      name = "Paperless";
      subdomain = "paperless.int.kuipr.de";
      hostname = "paperless";
      port = 8000;
    };

    nixosModules.paperless = {
      lib,
      config,
      ...
    }: let
      dataDir = "/var/lib/paperless";
      mediaDir = "/media/data/data/Paperless-data";
      consumeDir = "/media/data/Paperless-ingest";
      oidcSecret = config.sops.secrets."paperless/oidc".path;
      # Written by the retired nixpkgs module; v3 rejects the default key.
      secretKeyFile = "${dataDir}/nixos-paperless-secret-key.env";
      containerData = "/usr/src/paperless/data";
      containerMedia = "/usr/src/paperless/media";
      containerConsume = "/usr/src/paperless/consume";
      uid = toString config.users.users.paperless.uid;
      gid = toString config.users.groups.paperless.gid;

      # Podman does not inherit image HEALTHCHECKs; retry until the process listens.
      tcpProbe = port: "bash -c 'n=0; until exec 3<>/dev/tcp/127.0.0.1/${toString port} 2>/dev/null; do n=$((n+1)); [ $n -ge 10 ] && exit 1; sleep 3; done'";
    in {
      sops.secrets."paperless/oidc" = {
        sopsFile = ../../secrets/sorbet/paperless-oidc;
        format = "binary";
        key = "";
        owner = "paperless";
        restartUnits = ["podman-paperless.service"];
      };

      # Pinned so the existing 315:315 ownership of the bind mounts stays valid.
      users.users.paperless = {
        isSystemUser = true;
        group = "paperless";
        uid = 315;
      };
      users.groups.paperless.gid = 315;

      virtualisation.oci-containers.containers = {
        paperless = {
          labels = traefikLabels;
          inherit (import ./_image.nix) image;
          volumes = [
            "${dataDir}:${containerData}"
            "${mediaDir}:${containerMedia}"
            "${consumeDir}:${containerConsume}"
          ];
          environment = {
            USERMAP_UID = uid;
            USERMAP_GID = gid;
            GRANIAN_HOST = "0.0.0.0";
            GRANIAN_PORT = "8000";
            GRANIAN_WORKERS = "1";
            PAPERLESS_REDIS = "redis://redis:6379";
            PAPERLESS_DATA_DIR = containerData;
            PAPERLESS_MEDIA_ROOT = containerMedia;
            PAPERLESS_CONSUMPTION_DIR = containerConsume;
            PAPERLESS_TIKA_ENABLED = "true";
            PAPERLESS_TIKA_ENDPOINT = "http://tika:9998";
            PAPERLESS_GOTENBERG_ENABLED = "true";
            PAPERLESS_TIKA_GOTENBERG_ENDPOINT = "http://gotenberg:3000";
            PAPERLESS_OCR_LANGUAGE = "deu+eng";
            PAPERLESS_TIME_ZONE = "Europe/Berlin";
            PAPERLESS_URL = "https://${vhost.subdomain}";
            PAPERLESS_PAGINATION = "50";
            PAPERLESS_PAGINATION_MAX = "100";
            PAPERLESS_PAGINATION_MIN = "10";
            PAPERLESS_LOGOUT_REDIRECT_URL = "https://${constants.idDomain}/logout";
            PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
            PAPERLESS_ACCOUNT_DEFAULT_HTTP_PROTOCOL = "https";
            PAPERLESS_ACCOUNT_EMAIL_VERIFICATION = "none";
            PAPERLESS_SOCIAL_AUTO_SIGNUP = "true";
            PAPERLESS_SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP = "admin";
            PAPERLESS_DISABLE_REGULAR_LOGIN = "true";
            PAPERLESS_REDIRECT_LOGIN_TO_SSO = "true";
            PAPERLESS_AI_ENABLED = "true";
            # No LLM on purpose: ai_suggestions 400s by design.
            PAPERLESS_AI_LLM_EMBEDDING_BACKEND = "ollama";
            # Text-only 270m variant: paperless only embeds text chunks.
            PAPERLESS_AI_LLM_EMBEDDING_MODEL = "embeddinggemma-2:270m";
            PAPERLESS_AI_LLM_EMBEDDING_ENDPOINT = "http://ollama:11434";
          };
          log-driver = "journald";
          extraOptions =
            [
              # --env-file cannot unescape the systemd-escaped OIDC JSON.
              "--env=PAPERLESS_SOCIALACCOUNT_PROVIDERS"
              "--env=PAPERLESS_SECRET_KEY"
              "--network=proxy:ip=${proxyIp}"
            ]
            ++ healthFlags {
              # Django derives ALLOWED_HOSTS from PAPERLESS_URL and answers 400 to
              # any other Host; traefik skips unhealthy containers.
              cmd = "sh -c 'n=0; until curl -fsS -o /dev/null -H Host:${vhost.subdomain} http://127.0.0.1:8000/; do n=$((n+1)); [ $n -ge 10 ] && exit 1; sleep 3; done'";
              startPeriod = "3m";
              timeout = "30s";
            };
        };

        paperless-tika = {
          image = "docker.io/apache/tika:latest@sha256:0f0fbd7f053a2a9941b816ce6d6974493f5527f40c4d3491f9c2cecec30e612c";
          log-driver = "journald";
          extraOptions =
            [
              "--network=proxy:ip=${tikaIp}"
              "--network-alias=tika"
            ]
            ++ healthFlags {
              cmd = tcpProbe 9998;
              startPeriod = "1m";
              timeout = "10s";
            };
        };

        paperless-gotenberg = {
          image = "docker.io/gotenberg/gotenberg:8@sha256:53073e798c8ef39ea2187e44cb67bab77894ea2509100b94c4fe3b461f7b2996";
          log-driver = "journald";
          extraOptions =
            [
              "--network=proxy:ip=${gotenbergIp}"
              "--network-alias=gotenberg"
            ]
            ++ healthFlags {
              cmd = tcpProbe 3000;
              startPeriod = "1m";
              timeout = "10s";
            };
        };

        paperless-redis = {
          image = "docker.io/library/redis:7@sha256:314425e49d4aad0c72746c97b72b5f258e8b5db372e61e0f1d9956866f3e0b7c";
          log-driver = "journald";
          extraOptions =
            [
              "--network=proxy:ip=${redisIp}"
              "--network-alias=redis"
            ]
            ++ healthFlags {
              cmd = "redis-cli ping";
              startPeriod = "10s";
              timeout = "10s";
            };
        };
      };

      systemd = {
        tmpfiles.rules = [
          "d ${dataDir} 0755 paperless paperless - -"
          "d ${mediaDir} 2775 paperless paperless - -"
          "d ${consumeDir} 0777 paperless paperless - -"
          "d /media/data/Paperless-export 0755 paperless paperless - -"
        ];

        services = let
          sidecars = ["podman-paperless-redis.service" "podman-paperless-tika.service" "podman-paperless-gotenberg.service"];
        in {
          "podman-paperless" = {
            # Redis is a hard need; ollama and the converters are soft.
            requires = ["podman-paperless-redis.service"];
            wants = ["podman-ollama.service" "podman-paperless-tika.service" "podman-paperless-gotenberg.service"];
            after = ["podman-ollama.service"] ++ sidecars;
            wantedBy = ["multi-user.target"];
            serviceConfig = {
              Restart = lib.mkOverride 90 "always";
              EnvironmentFile = [oidcSecret secretKeyFile];
            };
          };

          "podman-paperless-tika".serviceConfig.Restart = lib.mkOverride 90 "always";
          "podman-paperless-gotenberg".serviceConfig.Restart = lib.mkOverride 90 "always";
          "podman-paperless-redis".serviceConfig.Restart = lib.mkOverride 90 "always";
        };
      };
    };
  };
}
