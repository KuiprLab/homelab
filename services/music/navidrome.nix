_: {
  flake = {
    # navidrome ext-auth header injection does not work through pangolin
    pangolinVirtualHosts."music" = {
      site = "sorbet";
      name = "Navidrome (ext)";
      subdomain = "music.ext.kuipr.de";
      port = 4533;
      private = false;
    };

    nixosModules.navidrome = {
      lib,
      config,
      ...
    }: let
      homeDir = "/home/daniel";
      musicFolder = "/media/data/music";
      inboxFolder = "${homeDir}/music-inbox";
      dataDir = "/var/lib/navidrome";
      pluginDir = "${dataDir}/plugins";
    in {
      sops.secrets."navidrome/env" = {
        sopsFile = ../../secrets/sorbet/navidrome.env;
        format = "dotenv";
        key = "";
        restartUnits = ["podman-navidrome.service"];
      };

      virtualisation.oci-containers.containers.navidrome = {
        image = "docker.io/deluan/navidrome:latest@sha256:38dc2727bfcfd5ede290f8ada114fc90368146f265ae4701ddddbcbe2a44ee52";
        volumes = [
          "${musicFolder}:/music:ro"
          "${dataDir}:/data"
        ];
        user = "${toString config.users.users.navidrome.uid}:${toString config.users.groups.navidrome.gid}";
        ports = ["127.0.0.1:4533:4533"];
        environmentFiles = [config.sops.secrets."navidrome/env".path];
        environment = {
          ND_MUSICFOLDER = "/music";
          ND_DATAFOLDER = "/data";
          ND_PORT = "4533";
          ND_PLUGINS_ENABLED = "true";
          ND_BACKUP_PATH = "/data/backups";
          ND_BACKUP_COUNT = "7";
          ND_BACKUP_SCHEDULE = "0 0 * * *";
          ND_LASTFM_ENABLED = "true";
          ND_COVERARTPRIORITY = "embedded, cover.*, folder.*, external";
          ND_ARTISTARTPRIORITY = "artist.*, album/artist.*, external";
          ND_SCANNER_PURGEMISSING = "always";
          ND_ENABLESHARING = "true";
          ND_AUTOIMPORTPLAYLISTS = "true";
          ND_SUBSONIC_DEFAULTREPORTREALPATH = "true";
          # caddy is native: the header arrives from the podman bridge gateway, not loopback
          ND_EXTAUTH_TRUSTEDSOURCES = "10.88.0.1/32";
          ND_EXTAUTH_USERHEADER = "Remote-User";
          ND_EXTAUTH_LOGOUTURL = "https://auth.ext.kuipr.de/logout";
          ND_ENABLEUSEREDITING = "false";
        };
        log-driver = "journald";
        extraOptions = [
          "--group-add=${toString config.users.groups.music.gid}"
          # podman's first health check fires immediately; retry or activation fails
          "--health-cmd=wget -q -O /dev/null http://127.0.0.1:4533/ping"
          "--health-interval=30s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=1m"
          "--health-timeout=10s"
        ];
      };

      systemd = {
        tmpfiles.rules = [
          "d ${pluginDir} 0750 navidrome navidrome - -"
          "d ${homeDir}/backups 0750 daniel daniel - -"
          "d ${musicFolder} 0775 daniel music - -"
          "d ${inboxFolder} 0775 daniel daniel - -"
        ];

        services."podman-navidrome".serviceConfig.Restart = lib.mkOverride 90 "always";
      };
    };
  };
}
