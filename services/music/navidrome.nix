# Navidrome in podman.
#
# State lives in /var/lib/navidrome (bind mount) so navidrome-gdrive-sync can keep
# reading the DB backups from the host as the navidrome user, and the music tree
# stays a read-only bind of /media/data/music.
#
# The container runs as the host's navidrome uid/gid (not 1000) so the existing
# 0700 state directory needs no chown, and --group-add music replaces the
# supplementary group the systemd unit used to get from users.extraGroups.
#
# Config is passed as ND_* env: Navidrome reads every settings key through viper
# with SetEnvPrefix("ND") and a "." -> "_" replacer, so Backup.Path becomes
# ND_BACKUP_PATH. The Last.fm keys already live in the sops env file that way.
_: {
  flake = {
    # External: proxied publicly by pangolin (music.ext.kuipr.de). Note
    # Navidrome's Externalized Authentication header injection no longer
    # works through pangolin — use pangolin's native dashboard accounts.
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
        # Match the on-disk owner of /var/lib/navidrome exactly.
        user = "${toString config.users.users.navidrome.uid}:${toString config.users.groups.navidrome.gid}";
        ports = ["127.0.0.1:4533:4533"];
        environmentFiles = [config.sops.secrets."navidrome/env".path];
        environment = {
          ND_MUSICFOLDER = "/music";
          ND_DATAFOLDER = "/data";
          ND_PORT = "4533";
          ND_PLUGINS_ENABLED = "true";
          # Inside the container, so the host backup dir and the gdrive sync agree.
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
          # caddy is native and reaches the container through the podman DNAT,
          # so the header arrives from the bridge gateway, not 127.0.0.1.
          ND_EXTAUTH_TRUSTEDSOURCES = "10.88.0.1/32";
          ND_EXTAUTH_USERHEADER = "Remote-User";
          ND_EXTAUTH_LOGOUTURL = "https://auth.ext.kuipr.de/logout";
          ND_ENABLEUSEREDITING = "false";
        };
        log-driver = "journald";
        extraOptions = [
          # /media/data/music is 0775 daniel:music; the process needs the music
          # group the systemd unit used to inherit from extraGroups.
          "--group-add=${toString config.users.groups.music.gid}"
          # Retry inside the command: podman's first check fires immediately at
          # start, and a failed transient-unit check aborts NixOS activations.
          # /ping is Navidrome's liveness endpoint and answers "pong".
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
