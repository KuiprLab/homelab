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
          # skip, not the home-manager default of merge: merging is right
          # when YOU are adding the missing half of an album, and wrong for
          # an unattended re-download, where it fuses the new copy into the
          # existing one and leaves a 12-track album that matches no 6-track
          # release. Observed on a second download of Epicus Doomicus
          # Metallicus: pass 1 matched it at 100%, the merge then scored
          # 79.4% and parked it in review.
          duplicate_action: skip
      '';
      # Second-pass config: used only after a plain import found no match
      # AND the bot left a hint naming the release. Forcing --search-id makes
      # beets score the files against a release they may not be from, so two
      # defaults have to give:
      #
      #   album_id (weight 5.0, the heaviest there is) penalises the file's
      #   own mb_albumid for differing from the forced one -- which is the
      #   whole point of forcing it. Measured on a Candlemass rip: 0.21 of
      #   the 0.21 remaining distance was this one penalty.
      #
      #   strong_rec_thresh absorbs what is left, since a rip beets could
      #   not place on its own is by definition an imperfect match.
      #
      # Neither belongs in the home-manager settings: they would then apply
      # to interactive imports and to unattended ones where beets is guessing.
      hintedImportConfig = pkgs.writeText "beets-hinted-import.yaml" ''
        import:
          quiet: yes
          quiet_fallback: skip
          # skip, not the home-manager default of merge: merging is right
          # when YOU are adding the missing half of an album, and wrong for
          # an unattended re-download, where it fuses the new copy into the
          # existing one and leaves a 12-track album that matches no 6-track
          # release. Observed on a second download of Epicus Doomicus
          # Metallicus: pass 1 matched it at 100%, the merge then scored
          # 79.4% and parked it in review.
          duplicate_action: skip
        match:
          strong_rec_thresh: 0.25
          distance_weights:
            album_id: 0.0
      '';
      # /music missing queues a download meant to fill gaps in an album the
      # library already has. That is the one case where merging beats skipping
      # the duplicate: the point is to end up with one complete album rather
      # than to protect the copy already there.
      completeImportConfig = pkgs.writeText "beets-complete-import.yaml" ''
        import:
          quiet: yes
          quiet_fallback: skip
          duplicate_action: merge
      '';
      importScript = pkgs.writeShellApplication {
        name = "slskd-beets-import";
        runtimeInputs = [beets pkgs.jq pkgs.findutils pkgs.coreutils pkgs.curl pkgs.gnused pkgs.gnugrep];
        text = ''
          # DISCORD_WEBHOOK_URL comes from the unit's EnvironmentFile
          notify() {
            [[ -n "''${DISCORD_WEBHOOK_URL:-}" ]] || return 0
            jq -n --arg c "🎵 slskd → beets: $1" '{content: $c}' \
              | curl -fsS -m 10 -H 'Content-Type: application/json' -d @- "$DISCORD_WEBHOOK_URL" \
              || echo "discord notification failed" >&2
          }

          # import.move=true empties a directory it fully imported, so
          # leftover audio means beets skipped the album.
          has_audio() {
            find "$1" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wav' \) -print -quit | grep -q .
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
            # What the bot said this album is, if it said anything. Looked
            # up now, used only if the plain import below comes up empty.
            mbid=""
            artist=""
            title=""
            complete=""
            dirname=$(basename "$dir")
            for hint in "${hintsDir}"/*.json; do
              [[ $(jq -r '.directory // empty' "$hint" 2>/dev/null) == "$dirname" ]] || continue
              mbid=$(jq -r '.releaseId // empty' "$hint" 2>/dev/null)
              artist=$(jq -r '.artist // empty' "$hint" 2>/dev/null)
              title=$(jq -r '.title // empty' "$hint" 2>/dev/null)
              complete=$(jq -r 'if .complete then "yes" else empty end' "$hint" 2>/dev/null)
              [[ -n "$mbid" ]] && echo "hint: $dirname is release $mbid"
              break
            done

            # A completion merges into what is already there; everything else
            # takes the default config, which skips duplicates outright.
            first_config="${autoImportConfig}"
            if [[ "$complete" == "yes" ]]; then
              echo "$dirname is completing an album already in the library"
              first_config="${completeImportConfig}"
            fi

            echo "importing $dir"
            # Tee'd, not just logged: quiet mode still prints the match it
            # applied, and that is the only place the album beets settled on
            # is named. The journal keeps getting it either way.
            log=$(mktemp)
            if ! beet -c "$first_config" import "$dir" 2>&1 | tee "$log"; then
              echo "beet import failed for $dir" >&2
              rm -f "$log"
              mv "$event" "${failedDir}/"
              notify "❌ beet import **failed** for \`$rel\` — see \`journalctl -u slskd-beets-import\`"
              continue
            fi

            # Already in the library: not a matching problem, and the hint
            # cannot help. beets logs its duplicate handling at debug level, so
            # the library is asked directly instead of parsing the output --
            # using what the bot recorded, since the folder name is the peer's
            # and says nothing reliable about artist or album.
            if [[ "$complete" != "yes" ]] && has_audio "$dir" &&
              [[ -n "$artist" && -n "$title" ]] &&
              beet ls -a "albumartist:$artist" "album:$title" | grep -q .; then
              echo "$dirname is already in the library"
              rm -f "$log"
              mv "$dir" "${reviewDir}/"
              rm -f "$event"
              notify "ℹ️ \`$rel\` is already in the library — the new copy is in \`${reviewDir}\`"
              continue
            fi

            # Only now is the hint worth anything. A rip carrying its own
            # tags matches its own release at distance ~0, and forcing the
            # release picked in Discord would score it against a different
            # pressing and lose -- measured at 0.31 against 0.00 on the same
            # files. So the hint is a lifeline for what beets could not
            # place, never the first thing tried.
            if [[ -n "$mbid" ]] && has_audio "$dir"; then
              echo "no match for $dirname, retrying with release $mbid"
              if ! beet -c "${hintedImportConfig}" import --search-id "$mbid" "$dir" 2>&1 | tee -a "$log"; then
                echo "hinted beet import failed for $dir" >&2
                rm -f "$log"
                mv "$event" "${failedDir}/"
                notify "❌ hinted beet import **failed** for \`$rel\` — see \`journalctl -u slskd-beets-import\`"
                continue
              fi
            fi

            if has_audio "$dir"; then
              echo "unmatched, moving $dir to ${reviewDir}"
              mv "$dir" "${reviewDir}/"
              notify "⚠️ no confident match for \`$rel\`, moved to \`${reviewDir}\` for manual import"
            else
              rm -rf "$dir"
              # beets prints "Match (100.0%):" and then the album it chose;
              # the codes are stripped because it colours its output even
              # when nothing is attached to read it.
              # || true: grep exits 1 when an import printed no match
              # line at all, and that must not take the unit down with set -e.
              matched=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -A1 -m1 "Match (" | tail -1 | sed 's/^ *//;s/ *$//' || true)
              if [[ -n "$matched" ]]; then
                notify "✅ imported \`$rel\` as **$matched**"
              else
                notify "✅ imported \`$rel\`"
              fi
            fi
            rm -f "$log"
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
              # 0, not 0.8: this penalty exists to hold the *other* metadata
              # sources below MusicBrainz, and beets weights it at 2.0 by
              # default (match.distance_weights.source). Set on MusicBrainz
              # itself it taxed every candidate from the source we prefer --
              # which is what put "data source" in the penalty list of an
              # otherwise clean match, and kept clean rips above
              # strong_rec_thresh no matter how small the real differences.
              data_source_mismatch_penalty = 0.0;
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
