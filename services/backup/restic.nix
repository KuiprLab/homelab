_: {
  flake.nixosModules.backupRestic = {
    config,
    lib,
    pkgs,
    ...
  }: let
    repository = "b2:kuipr-restic";
    stageDir = "/var/lib/backup-stage";
    verifyDir = "/var/lib/backup-verify";
    # One snapshot per night: restic forget keeps only the newest snapshot of each period.
    tagArgs = lib.concatMapStrings (tag: "--tag ${tag} ") ["navidrome" "koito" "aurral" "manifest"];
    secrets = config.sops.secrets;
    stageExport = pkgs.writeShellScript "stage-export" (builtins.readFile ./_stage-export.sh);
    backupEnv = {
      EnvironmentFile = [secrets."restic/env".path secrets."restic/ping".path];
      Environment = [
        "RESTIC_REPOSITORY=${repository}"
        "RESTIC_CACHE_DIR=/var/cache/restic"
      ];
    };
  in {
    sops.secrets = {
      # Both files are binary sops blobs holding dotenv text; systemd parses them as EnvironmentFile.
      "restic/env" = {
        sopsFile = ../../secrets/sorbet/restic.env;
        format = "env";
        key = "";
        owner = "root";
        mode = "0400";
      };

      "restic/ping" = {
        sopsFile = ../../secrets/sorbet/restic-ping.env;
        format = "env";
        key = "";
        owner = "root";
        mode = "0400";
      };
    };

    systemd = {
      tmpfiles.rules = [
        "d /var/cache/restic 0700 root root - -"
      ];

      services.restic-backup = {
        description = "Stage homelab state and back it up to Backblaze B2";
        after = ["network-online.target"];
        wants = ["network-online.target"];
        path = [pkgs.coreutils pkgs.curl pkgs.findutils pkgs.restic pkgs.sqlite];
        script = ''
          set -eu

          hc() {
            curl -fsS --max-time 10 --retry 3 "$1" >/dev/null
          }

          hc "$RESTIC_BACKUP_PING/start" || true
          ${stageExport}

          if ! restic backup ${tagArgs}--pack-size 64 ${stageDir}; then
            echo "restic backup failed" >&2
            hc "$RESTIC_BACKUP_PING/fail" || true
            exit 1
          fi
          hc "$RESTIC_BACKUP_PING" || true
        '';
        serviceConfig = backupEnv // {Type = "oneshot";};
      };

      timers.restic-backup = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "03:30";
          RandomizedDelaySec = "15m";
          Persistent = true;
        };
      };

      services.restic-prune = {
        description = "Apply restic retention and prune the B2 repository";
        after = ["network-online.target"];
        wants = ["network-online.target"];
        path = [pkgs.curl pkgs.restic];
        script = ''
          set -eu

          hc() {
            curl -fsS --max-time 10 --retry 3 "$1" >/dev/null
          }

          # Monthly, not nightly: B2 grants 2500 class B and 2500 class C operations per day.
          if ! restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune; then
            echo "restic prune failed" >&2
            hc "$RESTIC_PRUNE_PING/fail" || true
            exit 1
          fi
          hc "$RESTIC_PRUNE_PING" || true
        '';
        serviceConfig = backupEnv // {Type = "oneshot";};
      };

      timers.restic-prune = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "*-*-01 04:00:00";
          Persistent = true;
        };
      };

      services.restic-verify = {
        description = "Verify the restic repository and prove a restore works";
        after = ["network-online.target"];
        wants = ["network-online.target"];
        path = [pkgs.coreutils pkgs.curl pkgs.restic pkgs.sqlite];
        script = ''
          set -eu

          hc() {
            curl -fsS --max-time 10 --retry 3 "$1" >/dev/null
          }

          fail() {
            echo "$1" >&2
            hc "$RESTIC_VERIFY_PING/fail" || true
            rm -rf ${verifyDir}
            exit 1
          }

          hc "$RESTIC_VERIFY_PING/start" || true
          rm -rf ${verifyDir}
          install -d -m 0700 ${verifyDir}

          restic check --read-data-subset=2% || fail "restic check failed"
          restic restore latest --tag navidrome --target ${verifyDir} || fail "restore failed"

          tracks=$(sqlite3 ${verifyDir}${stageDir}/navidrome/navidrome.db \
            "select count(*) from media_file")
          [ "$tracks" -ge 1000 ] || fail "restored database holds $tracks tracks"

          rm -rf ${verifyDir}
          hc "$RESTIC_VERIFY_PING" || true
        '';
        serviceConfig = backupEnv // {Type = "oneshot";};
      };

      timers.restic-verify = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "*-*-08 05:00:00";
          Persistent = true;
        };
      };
    };
  };
}
