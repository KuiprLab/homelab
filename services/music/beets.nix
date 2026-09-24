# Beets home-manager configuration and slskd → beets import bridge.
#
# slskd runs a script on DownloadDirectoryComplete (configured in the slskd.yml
# secret) that dumps the event JSON into /app/events, which is
# /var/lib/slskd/events on the host. A path unit picks each event up and runs a
# non-interactive `beet import` on the finished directory. Anything beets can't
# match confidently is skipped and moved to ~/music-inbox/slskd-review for a
# manual `just beet import`.
_: {
  flake = {
    nixosModules.beets = {
      pkgs,
      config,
      ...
    }: let
      musicFolder = "/media/data/music/beetroot";
      eventsDir = "/var/lib/slskd/events";
      failedDir = "/var/lib/slskd/events-failed";
      reviewDir = "/home/daniel/music-inbox/slskd-review";
      # homelab-bot drops one JSON file per queued download here, naming the
      # MusicBrainz release the user actually picked. The directory is created
      # by apps/homelab-bot/_module.nix (setgid daniel:users); this unit only
      # reads, and the bot prunes its own stale files.
      hintsDir = "/var/lib/beets-hints";
      # Container path of the downloads dir (see slskd.nix volumes) → host path
      containerDownloads = "/app/downloads";
      hostDownloads = "/home/daniel/slskd-downloads";
      beets = config.home-manager.users.daniel.programs.beets.package;
      # Overrides for the unattended run only; interactive imports keep the
      # home-manager defaults (quiet_fallback = asis would import untagged junk).
      autoImportConfig = pkgs.writeText "beets-auto-import.yaml" ''
        import:
          quiet: yes
          quiet_fallback: skip
      '';
      # Used only when a hint named the release (see hintsDir). The album's
      # identity is then the one the user picked in Discord rather than
      # beets' own guess, so the threshold only has to absorb tagging noise:
      # a Soulseek rip routinely differs from the canonical release by
      # capitalisation, a curly apostrophe or a bonus track, which together
      # score well past the 0.10 a guessed match has to clear.
      #
      # The looser number is deliberately NOT in the home-manager settings:
      # it would then apply to interactive imports and to unattended ones
      # where beets has no idea what the album is.
      hintedImportConfig = pkgs.writeText "beets-hinted-import.yaml" ''
        import:
          quiet: yes
          quiet_fallback: skip
        match:
          strong_rec_thresh: 0.25
      '';
      importScript = pkgs.writeShellApplication {
        name = "slskd-beets-import";
        runtimeInputs = [beets pkgs.jq pkgs.findutils pkgs.coreutils pkgs.curl];
        text = ''
          # DISCORD_WEBHOOK_URL comes from the unit's EnvironmentFile
          notify() {
            [[ -n "''${DISCORD_WEBHOOK_URL:-}" ]] || return 0
            jq -n --arg c "🎵 slskd → beets: $1" '{content: $c}' \
              | curl -fsS -m 10 -H 'Content-Type: application/json' -d @- "$DISCORD_WEBHOOK_URL" \
              || echo "discord notification failed" >&2
          }

          mkdir -p "${reviewDir}" "${failedDir}"
          shopt -s nullglob
          for event in "${eventsDir}"/*.json; do
            # Never let one bad event take the unit down: park it and move on,
            # otherwise the path unit retriggers until it hits its start limit.
            # remoteDirectoryName holds Windows-style paths whose backslashes get
            # mangled if the slskd-side script uses echo instead of printf; the
            # local path is a plain Linux path, so fall back to a regex for it.
            if ! rel=$(jq -r '.localDirectoryName // empty' "$event" 2>/dev/null); then
              echo "event $event: invalid JSON, extracting localDirectoryName with sed" >&2
              rel=$(sed -n 's/.*"localDirectoryName":"\([^"]*\)".*/\1/p' "$event")
            fi
            rel=''${rel#${containerDownloads}/}
            dir="${hostDownloads}/$rel"
            if [[ -z "$rel" || ! -d "$dir" ]]; then
              echo "event $event: directory '$dir' missing, parking event" >&2
              mv "$event" "${failedDir}/"
              notify "directory \`$dir\` missing, event parked in \`${failedDir}\`"
              continue
            fi
            # The bot knew the release id at click time; without it beets has to
            # re-derive the release from a folder like
            # "1992 - Tomb of the Mutilated {2002 RE RM Bonus ...} [FLAC]", which
            # scores far enough off the original release that quiet_fallback=skip
            # parks the album in review. --search-id gives beets the answer.
            search=()
            beet_config=${autoImportConfig}
            dirname=$(basename "$dir")
            for hint in "${hintsDir}"/*.json; do
              [[ $(jq -r '.directory // empty' "$hint" 2>/dev/null) == "$dirname" ]] || continue
              mbid=$(jq -r '.releaseId // empty' "$hint" 2>/dev/null)
              if [[ -n "$mbid" ]]; then
                echo "hint: $dirname is release $mbid"
                search=(--search-id "$mbid")
                beet_config=${hintedImportConfig}
              fi
              break
            done

            echo "importing $dir"
            if ! beet -c "$beet_config" import "''${search[@]}" "$dir"; then
              echo "beet import failed for $dir" >&2
              mv "$event" "${failedDir}/"
              notify "❌ beet import **failed** for \`$rel\` — see \`journalctl -u slskd-beets-import\`"
              continue
            fi
            # import.move=true empties the dir on success; leftovers were skipped
            if find "$dir" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wav' \) -print -quit | grep -q .; then
              echo "unmatched, moving $dir to ${reviewDir}"
              mv "$dir" "${reviewDir}/"
              notify "⚠️ no confident match for \`$rel\`, moved to \`${reviewDir}\` for manual import"
            else
              rm -rf "$dir"
            fi
            rm -f "$event"
          done
        '';
      };
      unitFailedScript = pkgs.writeShellApplication {
        name = "slskd-beets-import-failed";
        runtimeInputs = [pkgs.jq pkgs.curl];
        text = ''
          [[ -n "''${DISCORD_WEBHOOK_URL:-}" ]] || exit 0
          jq -n --arg c "🎵 slskd → beets: ❌ \`slskd-beets-import.service\` crashed — see \`journalctl -u slskd-beets-import\`" '{content: $c}' \
            | curl -fsS -m 10 -H 'Content-Type: application/json' -d @- "$DISCORD_WEBHOOK_URL"
        '';
      };
    in {
      # Same encrypted env file gatus uses (DISCORD_WEBHOOK_URL=...); systemd
      # reads EnvironmentFile as root before dropping to daniel.
      sops.secrets."beets/discord_webhook" = {
        sopsFile = ../../secrets/sorbet/gatus;
        format = "binary";
        key = "";
        owner = "root";
      };

      systemd = {
        tmpfiles.rules = [
          "d ${eventsDir} 0755 daniel users - -"
          "d ${failedDir} 0755 daniel users - -"
          "d ${reviewDir} 0775 daniel daniel - -"
        ];

        paths.slskd-beets-import = {
          description = "Watch for slskd download-complete events";
          wantedBy = ["multi-user.target"];
          pathConfig.DirectoryNotEmpty = eventsDir;
        };

        services = {
          slskd-beets-import = {
            description = "Import finished slskd downloads into beets";
            unitConfig.OnFailure = ["slskd-beets-import-failed.service"];
            serviceConfig = {
              Type = "oneshot";
              User = "daniel";
              Group = "users";
              EnvironmentFile = config.sops.secrets."beets/discord_webhook".path;
              ExecStart = "${importScript}/bin/slskd-beets-import";
            };
            environment.HOME = "/home/daniel";
          };

          # Per-event problems are reported by the script itself; this only
          # fires if the unit as a whole dies (script bug, missing binary, ...).
          slskd-beets-import-failed = {
            description = "Notify Discord that slskd-beets-import crashed";
            serviceConfig = {
              Type = "oneshot";
              EnvironmentFile = config.sops.secrets."beets/discord_webhook".path;
              ExecStart = "${unitFailedScript}/bin/slskd-beets-import-failed";
            };
          };
        };
      };

      sops.secrets."beets/acoustid_key" = {
        sopsFile = ../../secrets/sorbet/beets;
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
