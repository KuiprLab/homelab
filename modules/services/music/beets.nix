# Beets auto-import pipeline and home-manager configuration
_: {
  flake = {
    nixosModules.beets = {pkgs, ...}: let
      musicFolder = "/media/data/music/beetroot";
    in {
      sops.secrets."beets/acoustid_key" = {
        sopsFile = ../../../secrets/sorbet/beets;
        format = "binary";
        key = "";
        owner = "daniel";
      };

      environment.systemPackages = [
        pkgs.rclone
        pkgs.chromaprint
        pkgs.gst_all_1.gstreamer
      ];

      home-manager.users.daniel = {
        programs.beets = {
          enable = true;
          settings = {
            directory = musicFolder;
            library = "/home/daniel/.beets/library.db";

            import = {
              move = true;
              write = true;
              autotag = true;
              quiet = false;
              timid = false;
              group_albums = true;
              quiet_fallback = "asis";
              duplicate_action = "merge";
            };

            bucket.bucket_alpha = [
              "A-D"
              "E-L"
              "M-R"
              "S-Z"
            ];

            replaygain = {
              auto = true;
              backend = "gstreamer";
            };

            paths = {
              default = "%bucket{$albumartist,alpha}/$albumartist/$album/$track $title";
              singleton = "%bucket{$artist,alpha}/$artist/$album/$title";
              comp = "Compilations/$album/$track $title";
            };

            plugins = [
              "chroma"
              "spotify"
              "fetchart"
              "embedart"
              "musicbrainz"
              "mbsync"
              "replaygain"
              "lyrics"
              "bucket"
              "missing"
              "lastgenre"
              "badfiles"
              "duplicates"
            ];

            badfiles = {
              commands = {
                flac = "${pkgs.flac}/bin/flac --test --warnings-as-errors --silent";
                m4a = "${pkgs.ffmpeg}/bin/ffprobe -v error";
                mp3 = "${pkgs.mp3val}/bin/mp3val -si";
                ogg = "${pkgs.vorbis-tools}/bin/ogginfo";
                opus = "${pkgs.opus-tools}/bin/opusinfo";
                wav = "${pkgs.ffmpeg}/bin/ffprobe -v error";
                aiff = "${pkgs.ffmpeg}/bin/ffprobe -v error";
              };
            };

            lastgenre = {
              auto = true;
              force = true;
              keep_existing = false;
            };

            musicbrainz = {
              user = "Frostplexx";
              pass = "\${MUSICBRAINZ_PASSWORD}";
              data_source_mismatch_penalty = 0.8;
            };

            spotify = {
              data_source_mismatch_penalty = 0.3;
            };

            chroma.auto = false;
            acoustid.apikey = "\${ACOUSTID_APIKEY}";
            match = {
              strong_rec_thresh = 0.10;
              max_rec = {
                missing_tracks = "strong";
                unmatched_tracks = "strong";
              };
              distance_weights.missing_tracks = 0.1;
            };

            embedart.auto = true;
            fetchart = {
              auto = true;
              sources = [
                "filesystem"
                "itunes"
                "fanarttv"
                "coverart"
              ];
            };
            lyrics = {
              auto = true;
              sources = ["lrclib"];
              synced = true;
            };
          };
        };
      };
    };
  };
}
