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
      hintsDir = "/var/lib/beets-hints";
      containerDownloads = "/app/downloads";
      hostDownloads = "/home/daniel/slskd-downloads";
      beets = config.home-manager.users.daniel.programs.beets.package;
      autoImportConfig = pkgs.writeText "beets-auto-import.yaml" ''
        import:
          quiet: yes
          quiet_fallback: skip
          # skip not merge: an unattended re-download would fuse into the existing album
          duplicate_action: skip
      '';
      hintedImportConfig = pkgs.writeText "beets-hinted-import.yaml" ''
        import:
          quiet: yes
          quiet_fallback: skip
          duplicate_action: skip
        match:
          strong_rec_thresh: 0.25
          distance_weights:
            album_id: 0.0
      '';
      completeImportConfig = pkgs.writeText "beets-complete-import.yaml" ''
        import:
          quiet: yes
          quiet_fallback: skip
          duplicate_action: merge
      '';
      retagDir = "/var/lib/beets-retag";
      retagImportConfig = pkgs.writeText "beets-retag-import.yaml" ''
        import:
          quiet: yes
          quiet_fallback: skip
        match:
          # --search-id fights album_id (weight 5.0), so the penalty has to go
          strong_rec_thresh: 0.5
          distance_weights:
            album_id: 0.0
      '';

      retagScript = pkgs.writeShellApplication {
        name = "beets-retag";
        runtimeInputs = [beets pkgs.jq pkgs.coreutils pkgs.curl pkgs.gnugrep];
        text = ''
          GOTIFY_TITLE="🏷️ beets retag"
          notify() {
            [[ -n "''${GOTIFY_TOKEN:-}" ]] || return 0
            jq -n --arg t "$GOTIFY_TITLE" --arg m "$1" \
              '{title: $t, message: $m, priority: 5, extras: {"client::display": {contentType: "text/markdown"}}}' \
              | curl -fsS -m 10 -H 'Content-Type: application/json' -d @- \
                  "http://127.0.0.1:8085/message?token=$GOTIFY_TOKEN" \
              || echo "gotify notification failed" >&2
          }

          shopt -s nullglob
          for request in "${retagDir}"/*.json; do
            album=$(jq -r '.albumId // empty' "$request" 2>/dev/null)
            mbid=$(jq -r '.releaseId // empty' "$request" 2>/dev/null)
            label=$(jq -r '.label // empty' "$request" 2>/dev/null)
            [[ -n "$label" ]] || label="album $album"

            if [[ -z "$album" || -z "$mbid" ]]; then
              echo "request $request: no album id or release id, dropping" >&2
              rm -f "$request"
              notify "❌ a retag request was malformed and has been dropped"
              continue
            fi

            echo "retagging album $album against release $mbid"
            if ! beet -c "${retagImportConfig}" import -L --search-id "$mbid" "id:$album"; then
              echo "retag of album $album failed" >&2
              rm -f "$request"
              notify "❌ retag of $label **failed** — see \`journalctl -u beets-retag\`"
              continue
            fi

            # a reimport replaces the album row, so check by release id, not album id
            if beet ls -a "mb_albumid:$mbid" | grep -q .; then
              notify "✅ retagged $label"
            else
              notify "⚠️ retag of $label did not apply — beets found no confident match for that release"
            fi

            rm -f "$request"
          done
        '';
      };

      importScript = pkgs.writeShellApplication {
        name = "slskd-beets-import";
        runtimeInputs = [beets pkgs.jq pkgs.findutils pkgs.coreutils pkgs.curl pkgs.gnused pkgs.gnugrep];
        text = ''
          GOTIFY_TITLE="🎵 slskd → beets"
          notify() {
            [[ -n "''${GOTIFY_TOKEN:-}" ]] || return 0
            jq -n --arg t "$GOTIFY_TITLE" --arg m "$1" \
              '{title: $t, message: $m, priority: 5, extras: {"client::display": {contentType: "text/markdown"}}}' \
              | curl -fsS -m 10 -H 'Content-Type: application/json' -d @- \
                  "http://127.0.0.1:8085/message?token=$GOTIFY_TOKEN" \
              || echo "gotify notification failed" >&2
          }

          has_audio() {
            find "$1" -type f \( -iname '*.flac' -o -iname '*.mp3' -o -iname '*.m4a' -o -iname '*.ogg' -o -iname '*.opus' -o -iname '*.wav' \) -print -quit | grep -q .
          }

          mkdir -p "${reviewDir}" "${failedDir}"
          shopt -s nullglob
          for event in "${eventsDir}"/*.json; do
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

            first_config="${autoImportConfig}"
            if [[ "$complete" == "yes" ]]; then
              echo "$dirname is completing an album already in the library"
              first_config="${completeImportConfig}"
            fi

            echo "importing $dir"
            log=$(mktemp)
            if ! beet -c "$first_config" import "$dir" 2>&1 | tee "$log"; then
              echo "beet import failed for $dir" >&2
              rm -f "$log"
              mv "$event" "${failedDir}/"
              notify "❌ beet import **failed** for \`$rel\` — see \`journalctl -u slskd-beets-import\`"
              continue
            fi

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

            # hint is a fallback: forcing a release scores a self-tagged rip worse
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
              # beets emits ANSI colour even to a pipe; grep exits 1 when no match
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
          [[ -n "''${GOTIFY_TOKEN:-}" ]] || exit 0
          jq -n --arg t "🎵 slskd → beets" --arg m "❌ \`slskd-beets-import.service\` crashed — see \`journalctl -u slskd-beets-import\`" \
            '{title: $t, message: $m, priority: 8, extras: {"client::display": {contentType: "text/markdown"}}}' \
            | curl -fsS -m 10 -H 'Content-Type: application/json' -d @- \
                "http://127.0.0.1:8085/message?token=$GOTIFY_TOKEN"
        '';
      };
    in {
      systemd = {
        tmpfiles.rules = [
          "d ${eventsDir} 0755 daniel users - -"
          "d ${failedDir} 0755 daniel users - -"
          "d ${reviewDir} 0775 daniel daniel - -"
        ];

        paths.beets-retag = {
          description = "Watch for retag requests from homelab-bot";
          wantedBy = ["multi-user.target"];
          pathConfig.DirectoryNotEmpty = retagDir;
        };

        paths.slskd-beets-import = {
          description = "Watch for slskd download-complete events";
          wantedBy = ["multi-user.target"];
          pathConfig.DirectoryNotEmpty = eventsDir;
        };

        services = {
          beets-retag = {
            description = "Apply retag requests from homelab-bot";
            serviceConfig = {
              Type = "oneshot";
              User = "daniel";
              Group = "users";
              EnvironmentFile = "-/var/lib/gotify-provision/beets.env";
              ExecStart = "${retagScript}/bin/beets-retag";
            };
            environment.HOME = "/home/daniel";
          };

          slskd-beets-import = {
            description = "Import finished slskd downloads into beets";
            unitConfig.OnFailure = ["slskd-beets-import-failed.service"];
            serviceConfig = {
              Type = "oneshot";
              User = "daniel";
              Group = "users";
              EnvironmentFile = "-/var/lib/gotify-provision/beets.env";
              ExecStart = "${importScript}/bin/slskd-beets-import";
            };
            environment.HOME = "/home/daniel";
          };

          slskd-beets-import-failed = {
            description = "Notify Gotify that slskd-beets-import crashed";
            serviceConfig = {
              Type = "oneshot";
              EnvironmentFile = "-/var/lib/gotify-provision/beets.env";
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
              # beets defaults this to 2.0 and applies it to MusicBrainz itself
              data_source_mismatch_penalty = 0.0;
            };

            spotify = {
              data_source_mismatch_penalty = 0.3;
            };

            chroma.auto = false;
            acoustid.apikey = "\${ACOUSTID_APIKEY}";
            match = {
              preferred = {
                media = ["CD" "Digital Media|File"];
                original_year = true;
              };

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
