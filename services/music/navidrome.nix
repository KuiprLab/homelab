{config, ...}: let
  constants = config.flake.constants;
  healthFlags = config.flake.healthFlags;
  proxyIp = "10.89.0.63";
  vhost = config.flake.pangolinVirtualHosts."music";
  labels =
    config.flake.pangolinRuleLabels "music"
    // config.flake.pangolinHealthcheckLabels "music" vhost
    // config.flake.pangolinPublicLabels "music" vhost;
in {
  flake = {
    podmanProxyHosts.navidrome.ip = proxyIp;

    # navidrome ext-auth header injection does not work through pangolin
    pangolinVirtualHosts."music" = {
      site = "sorbet";
      name = "Navidrome (ext)";
      subdomain = "music.ext.kuipr.de";
      hostname = "navidrome";
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
        inherit labels;
        image = "docker.io/deluan/navidrome:latest@sha256:38dc2727bfcfd5ede290f8ada114fc90368146f265ae4701ddddbcbe2a44ee52";
        volumes = [
          "${musicFolder}:/music:ro"
          "${dataDir}:/data"
        ];
        user = "${toString config.users.users.navidrome.uid}:${toString config.users.groups.navidrome.gid}";
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
          # the edge is a container: the header arrives from the proxy network gateway
          ND_EXTAUTH_TRUSTEDSOURCES = "${constants.proxyGateway}/32";
          ND_EXTAUTH_USERHEADER = "Remote-User";
          ND_EXTAUTH_LOGOUTURL = "https://${constants.idDomain}/logout";
          ND_ENABLEUSEREDITING = "false";
        };
        log-driver = "journald";
        extraOptions =
          [
            "--group-add=${toString config.users.groups.music.gid}"
            "--network=proxy:ip=${proxyIp}"
            # podman's first health check fires immediately; retry or activation fails
          ]
          ++ healthFlags {
            cmd = "wget -q -O /dev/null http://127.0.0.1:4533/ping";
            startPeriod = "1m";
            timeout = "10s";
          };
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
