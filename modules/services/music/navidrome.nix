# Navidrome service, plugins, tmpfiles, and music-tagger
_: {
  flake.nixosModules.navidrome = {
    lib,
    config,
    ...
  }: let
    homeDir = "/home/daniel";
    musicFolder = "/media/data/music";
    inboxFolder = "${homeDir}/music-inbox";
    pluginDir = "/var/lib/navidrome/plugins";
    # mkPlugin = {
    #   name,
    #   url,
    #   hash,
    # }: {
    #   pkg = pkgs.fetchurl {inherit url hash;};
    #   inherit name;
    # };
    #
    # plugins = [
    # ];
  in {
    sops.secrets."navidrome/env" = {
      sopsFile = ../../../secrets/sorbet/navidrome.env;
      format = "dotenv";
      key = "";
    };

    systemd = {
      services.navidrome.serviceConfig = {
        BindReadOnlyPaths = [musicFolder];
        EnvironmentFile = config.sops.secrets."navidrome/env".path;
        ProtectHome = lib.mkForce false;
      };

      tmpfiles.rules = [
        "d ${pluginDir} 0750 navidrome navidrome - -"
        "d ${homeDir}/backups 0750 daniel daniel - -"
        "d ${musicFolder} 0775 daniel music - -"
        "d ${inboxFolder} 0775 daniel daniel - -"
      ];
      # ++ map (p: "L+ ${pluginDir}/${p.name}.ndp - - - - ${p.pkg}") plugins;
    };

    services.navidrome = {
      enable = true;
      settings = {
        MusicFolder = musicFolder;
        "Plugins.Enabled" = true;
        "Backup.Path" = "/var/lib/navidrome/backups";
        "Backup.Count" = 7;
        "Backup.Schedule" = "0 0 * * *";
        # Last.fm: artist bios, images, similar artists, top songs, album art
        # API keys injected via ND_LASTFM_APIKEY / ND_LASTFM_SECRET from sops
        "LastFM.Enabled" = true;

        "CoverArtPriority" = "embedded, cover.*, folder.*, external";
        "ArtistArtPriority" = "artist.*, album/artist.*, external";
        "Scanner.PurgeMissing" = "always";
        "EnableSharing" = true;
        "AutoImportPlaylists" = true;
        "Subsonic.DefaultReportRealPath" = true;
        "ExtAuth.TrustedSources" = "127.0.0.1/32";
        "ExtAuth.UserHeader" = "Remote-User";
        "ExtAuth.LogoutURL" = "https://auth.ext.kuipr.de/logout";
        "EnableUserEditing" = false;
      };
    };
  };
}
