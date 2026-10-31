_: {
  flake = {
    pangolinVirtualHosts."paperless" = {
      site = "sorbet";
      name = "Paperless";
      subdomain = "paperless.int.kuipr.de";
      port = 28981;
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
      tcpProbe = port: "--health-cmd=bash -c 'n=0; until exec 3<>/dev/tcp/127.0.0.1/${toString port} 2>/dev/null; do n=$((n+1)); [ $n -ge 10 ] && exit 1; sleep 3; done'";
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
          image = "ghcr.io/paperless-ngx/paperless-ngx:latest@sha256:1a08d8dfc2b51a08de09652dd86ad4d0c611c362382f944533ad38b73125fbc4";
          volumes = [
            "${dataDir}:${containerData}"
            "${mediaDir}:${containerMedia}"
            "${consumeDir}:${containerConsume}"
          ];
          ports = ["127.0.0.1:28981:8000"];
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
            PAPERLESS_URL = "https://paperless.int.kuipr.de";
            PAPERLESS_PAGINATION = "50";
            PAPERLESS_PAGINATION_MAX = "100";
            PAPERLESS_PAGINATION_MIN = "10";
            PAPERLESS_LOGOUT_REDIRECT_URL = "https://auth.ext.kuipr.de/logout";
            PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
            PAPERLESS_ACCOUNT_DEFAULT_HTTP_PROTOCOL = "https";
            PAPERLESS_ACCOUNT_EMAIL_VERIFICATION = "none";
            PAPERLESS_SOCIAL_AUTO_SIGNUP = "true";
            PAPERLESS_SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP = "paperless-admins";
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
          extraOptions = [
            # --env-file cannot unescape the systemd-escaped OIDC JSON.
            "--env=PAPERLESS_SOCIALACCOUNT_PROVIDERS"
            "--env=PAPERLESS_SECRET_KEY"
            "--health-cmd=sh -c 'n=0; until curl -fsS -o /dev/null http://127.0.0.1:8000/; do n=$((n+1)); [ $n -ge 10 ] && exit 1; sleep 3; done'"
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=3m"
            "--health-timeout=30s"
          ];
        };

        paperless-tika = {
          image = "docker.io/apache/tika:latest@sha256:b99f19c4fd76237dafe7d22f719b9bddfa9a449da687c597a41e2f6d9a595418";
          log-driver = "journald";
          extraOptions = [
            "--network-alias=tika"
            (tcpProbe 9998)
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=1m"
            "--health-timeout=10s"
          ];
        };

        paperless-gotenberg = {
          image = "docker.io/gotenberg/gotenberg:8@sha256:13672f317b443c793e972b1bd2155ec62a3e7b6891b411e8196442cc053ee5f5";
          log-driver = "journald";
          extraOptions = [
            "--network-alias=gotenberg"
            (tcpProbe 3000)
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=1m"
            "--health-timeout=10s"
          ];
        };

        paperless-redis = {
          image = "docker.io/library/redis:7@sha256:b6b6e3dc0c0952737748e55d5d885272840c7e42ba41ab1d5489f693419882f5";
          log-driver = "journald";
          extraOptions = [
            "--network-alias=redis"
            "--health-cmd=redis-cli ping"
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=10s"
            "--health-timeout=10s"
          ];
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
