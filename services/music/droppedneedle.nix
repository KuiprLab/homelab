{config, ...}: let
  constants = config.flake.constants;
  healthFlags = config.flake.healthFlags;
  proxyIp = "10.89.0.25";
  vhost = config.flake.pangolinVirtualHosts."needle";
  traefikLabels = config.flake.sorbetTraefikLabels "needle" vhost;
  dataDir = "/var/lib/droppedneedle";
  secretFile = ../../secrets/sorbet/droppedneedle.env;
  # The app runs without it; the converge unit appears once the secret is committed.
  converge = builtins.pathExists secretFile;
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

    nixosModules.droppedneedle = {
      config,
      lib,
      pkgs,
      ...
    }: let
      convergeScript = pkgs.writeShellApplication {
        name = "droppedneedle-converge";
        runtimeInputs = [pkgs.curl pkgs.jq pkgs.coreutils];
        text = builtins.readFile ./_droppedneedle/converge.sh;
      };
    in {
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

      sops.secrets."droppedneedle/env" = lib.mkIf converge {
        sopsFile = secretFile;
        format = "dotenv";
        key = "";
        restartUnits = ["droppedneedle-converge.service"];
      };

      systemd.services.droppedneedle-converge = lib.mkIf converge {
        description = "Converge DroppedNeedle settings from git";
        wantedBy = ["multi-user.target"];
        after = ["podman-needle.service"];
        wants = ["podman-needle.service"];
        restartTriggers = [convergeScript];

        environment = {
          DN_BASE_URL = "http://${vhost.hostname}:${toString vhost.port}";
          DN_ADMIN_USER = "daniel";
          DN_LIBRARY_PATH = "/data/music";
          DN_MB_SOURCE = "official";
          DN_MB_RATE_LIMIT = "1";
          DN_SLSKD_URL = "http://gluetun:5030";
          DN_NAVIDROME_URL = "http://navidrome:4533";
          DN_NAVIDROME_USER = "daniel";
          DN_NAVIDROME_PLAYLIST_PATH = "/data/music/_playlists";
          DN_OIDC_ISSUER = "https://${constants.idDomain}";
          DN_OIDC_CLIENT_ID = "droppedneedle";
          DN_OIDC_REDIRECT_URI = "https://${vhost.subdomain}/api/v3/auth/oidc/callback";
          DN_OIDC_SCOPES = "openid email profile";
        };

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          EnvironmentFile = config.sops.secrets."droppedneedle/env".path;
          ExecStart = lib.getExe convergeScript;
          Restart = "on-failure";
          RestartSec = "30s";
          StartLimitBurst = 5;
        };
      };

      systemd.tmpfiles.rules = [
        "d ${dataDir}/config 0755 daniel users - -"
        "d ${dataDir}/cache 0755 daniel users - -"
        "d ${dataDir}/plugins 0755 daniel users - -"
        "d ${dataDir}/imports 0755 daniel users - -"
        "d /media/data/slskd/complete 0775 daniel music - -"
        "d /media/data/music/_playlists 0775 daniel music - -"
      ];
    };
  };
}
