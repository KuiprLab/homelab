# Apollo backend (Apollo-Reborn) — sorbet, sized for one or two users.
#
# Same containers as upstream docker-compose.yml, minus the two that only
# matter at scale:
#   - pgbouncer: the app opens at most ~27 connections (api 16, scheduler 1,
#     one small pool per worker), well under postgres' 100.
#   - statsd: an empty STATSD_URL makes the Datadog client a no-op
#     (internal/cmdutil/cmdutil.go:82), so there is no sink to run.
#
# Container names stay identical to compose because the env file and
# docker/migrate.sh address each other by name (`postgres`, `redis-queue`,
# `redis-locks`); they are therefore global on this host.
#
# apollo.ext.kuipr.de is a public proxy-resource: traffic terminates on
# eclair's traefik, crosses the pangolin tunnel and lands on api's loopback
# port. The API has no login (a mobile client cannot do pangolin SSO);
# REGISTRATION_SECRET is the only gate.
_: {
  flake = {
    pangolinVirtualHosts."apollo" = {
      site = "sorbet";
      name = "Apollo";
      subdomain = "apollo.ext.kuipr.de";
      port = 4000;
      private = false;
      # `/` is a mux 404 (only /v1/* and /api/* are registered). With the
      # default "/" probe the target stays unhealthy and pangolin stops
      # routing to it.
      healthcheck.path = "/v1/health";
    };

    nixosModules.apollo = {
      config,
      lib,
      pkgs,
      ...
    }: let
      # Bump rev and image digest together: the mounted schema/patches come
      # from this tree, the binary from that image.
      src = pkgs.fetchFromGitHub {
        owner = "apollo-reborn";
        repo = "apollo-backend";
        rev = "392be173fd6d645891e03cc029ac06d746f0913d";
        hash = "sha256-Odo2jCb/jJvLZm9Fndgo9q1/Zvm9JgN5qKDIrrO1Mlk=";
      };

      appImage = "ghcr.io/apollo-reborn/apollo-backend:latest@sha256:d67a280e87167c29e64b7d8ff630b6c90c953c38ec69feffdaec7e73668b77a6";
      postgresImage = "docker.io/library/postgres:14-alpine@sha256:50fce0c9c54c43d8b02ce16cb9daff75eb94c09c4ee3d41c157852ebd9700c80";

      envFile = config.sops.secrets."apollo/env".path;
      # The image runs as its unprivileged `apollo` user, hence the 0444 mount
      # source (see the secret below).
      appVolumes = ["${config.sops.secrets."apollo/apple-key".path}:/etc/secrets/apple.p8:ro"];

      # compose's depends_on, reduced to start ordering. postgres and redis
      # are sdnotify=healthy, so a dependent starts once they accept
      # connections. migrate gets a head start; a first-boot race with the
      # schema load is absorbed by the systemd restart rather than gated by a
      # poll.
      dependsOn = ["postgres" "redis-queue" "redis-locks" "migrate"];

      mkApp = {
        cmd,
        health,
        extra ? {},
      }:
        {
          image = appImage;
          inherit cmd;
          environmentFiles = [envFile];
          volumes = appVolumes;
          inherit dependsOn;
          log-driver = "journald";
          extraOptions =
            [
              # Podman kills an unhealthy container and the unit's Restart=
              # recreates it (podman advises against --restart under systemd).
              "--health-on-failure=kill"
            ]
            ++ health;
        }
        // extra;

      workerHealth = [
        "--health-cmd=pgrep apollo"
        "--health-interval=30s"
        "--health-timeout=5s"
        "--health-retries=3"
      ];

      # One process per queue: the binary takes a single --queue. Consumer
      # counts also size the pools (db = consumers/16, min 1; redis =
      # consumers/4), which is why they are single-digit here.
      workers = {
        scheduler = ["scheduler"];
        worker-notifications = ["worker" "--queue" "notifications" "--consumers" "4"];
        worker-stuck-notifications = ["worker" "--queue" "stuck-notifications" "--consumers" "1"];
        worker-subreddits = ["worker" "--queue" "subreddits" "--consumers" "2"];
        worker-trending = ["worker" "--queue" "trending" "--consumers" "1"];
        worker-users = ["worker" "--queue" "users" "--consumers" "1"];
        worker-live-activities = ["worker" "--queue" "live-activities" "--consumers" "1"];
      };

      # Two instances on purpose: rmq queues vs Lua-script dedup locks.
      mkRedis = {
        image = "docker.io/library/redis:8-alpine@sha256:9f8d2d789b9a1d1e3f283f979aa9cbf393373806472e1ccd460e2f9c869b833b";
        cmd = ["redis-server" "--maxmemory-policy" "noeviction"];
        # Ready once the healthcheck passes, which is how dependents get
        # compose's `condition: service_healthy`.
        podman.sdnotify = "healthy";
        log-driver = "journald";
        extraOptions = [
          "--health-cmd=redis-cli ping"
          "--health-interval=5s"
          "--health-timeout=3s"
          "--health-retries=10"
        ];
      };

      appUnits = map (n: "podman-${n}.service") (lib.attrNames workers);
    in {
      # Whole .env.docker as one sops dotenv file, handed to every app
      # container as --env-file. Hosts are `postgres`, `redis-queue` and
      # `redis-locks` because the containers keep those names.
      sops.secrets."apollo/env" = {
        sopsFile = ../secrets/sorbet/apollo.env;
        format = "dotenv";
        key = "";
        restartUnits = appUnits;
      };

      sops.secrets."apollo/apple-key" = {
        sopsFile = ../secrets/sorbet/apollo_key.p8;
        format = "binary";
        key = "";
        # Not root-only: the mounted key has to be readable by the image's
        # unprivileged apollo user (sops' 0400 default is not).
        mode = "0444";
        restartUnits = appUnits;
      };

      systemd = {
        tmpfiles.rules = [
          "d /var/lib/apollo 0750 root root -"
          "d /var/lib/apollo/postgres 0700 root root -"
        ];

        services =
          {
            # compose: `restart: "no"` on migrate — a failing migration must
            # not retry in a loop.
            "podman-migrate".serviceConfig.Restart = lib.mkForce "no";
          }
          // lib.genAttrs appUnits (_: {
            # Also the backoff for a first-boot start before the schema is
            # loaded.
            serviceConfig.RestartSec = "10s";
          });
      };

      virtualisation.oci-containers.containers =
        {
          postgres = {
            image = postgresImage;
            environment = {
              POSTGRES_USER = "apollo";
              POSTGRES_PASSWORD = "apollo";
              POSTGRES_DB = "apollo";
            };
            volumes = ["/var/lib/apollo/postgres:/var/lib/postgresql/data:rw"];
            podman.sdnotify = "healthy";
            log-driver = "journald";
            extraOptions = [
              "--health-cmd=pg_isready -U apollo -d apollo"
              "--health-interval=5s"
              "--health-timeout=3s"
              "--health-retries=10"
              "--health-start-period=10s"
            ];
          };

          redis-queue = mkRedis;
          redis-locks = mkRedis;

          # Loads docs/schema.sql (the consolidated schema the CI uses) plus
          # the two patches that were added after it; the step migrations in
          # migrations/ cannot run on a clean DB (000006 and 000008 create the
          # same index).
          migrate = {
            image = postgresImage;
            environment.PGPASSWORD = "apollo";
            entrypoint = "/migrate.sh";
            volumes = [
              "${src}/docs/schema.sql:/schema.sql:ro"
              "${src}/docker/migrate.sh:/migrate.sh:ro"
              "${src}/migrations/000013_restore_live_activities.up.sql:/patches/000013_restore_live_activities.up.sql:ro"
              "${src}/migrations/000014_add_device_transport.up.sql:/patches/000014_add_device_transport.up.sql:ro"
            ];
            dependsOn = ["postgres"];
            log-driver = "journald";
          };

          api = mkApp {
            cmd = ["api"];
            health = [
              "--health-cmd=wget -qO- http://localhost:4000/v1/health >/dev/null"
              "--health-interval=15s"
              "--health-timeout=3s"
              "--health-retries=5"
              "--health-start-period=30s"
            ];
            extra.ports = ["127.0.0.1:4000:4000"];
          };
        }
        // lib.mapAttrs (_: cmd:
          mkApp {
            inherit cmd;
            health = workerHealth;
          })
        workers;
    };
  };
}
