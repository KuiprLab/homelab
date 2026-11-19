_: {
  flake.nixosModules.backupBtrfsSnapshots = {pkgs, ...}: let
    fs = "/media/data";
    snapDir = "${fs}/.snapshots";
    keepCount = 28;
  in {
    systemd = {
      tmpfiles.rules = [
        "d ${snapDir} 0700 root root - -"
      ];

      services = {
        btrfs-snapshot = {
          description = "Snapshot ${fs} read-only";
          path = [pkgs.btrfs-progs pkgs.coreutils pkgs.findutils];
          # Not a backup: same disk. It only buys time against deletion by a bad sync.
          script = ''
            set -eu
            btrfs subvolume snapshot -r ${fs} ${snapDir}/$(date +%Y%m%d-%H%M%S)

            mapfile -t snapshots < <(find ${snapDir} -mindepth 1 -maxdepth 1 -type d -name '2*' | sort)
            excess=$(( ''${#snapshots[@]} - ${toString keepCount} ))
            for (( i = 0; i < excess; i++ )); do
              btrfs subvolume delete "''${snapshots[i]}"
            done
          '';
          serviceConfig = {
            Type = "oneshot";
            Nice = 10;
          };
        };

        btrfs-scrub = {
          description = "Scrub ${fs}";
          path = [pkgs.btrfs-progs pkgs.coreutils];
          script = ''
            set -eu
            btrfs scrub start -B ${fs}
            btrfs scrub status -d ${fs}
          '';
          serviceConfig = {
            Type = "oneshot";
            Nice = 10;
            IOSchedulingClass = "idle";
          };
        };
      };

      timers = {
        btrfs-snapshot = {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = "00/6:00:00";
            Persistent = true;
          };
        };

        btrfs-scrub = {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnCalendar = "monthly";
            Persistent = true;
          };
        };
      };
    };
  };
}
