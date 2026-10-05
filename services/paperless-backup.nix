# Off-box backup for paperless-ngx (sorbet).
#
# One chain, one signal:
#   paperless-exporter.service   (nixpkgs `services.paperless.exporter`)
#     └─ onSuccess → paperless-backup.service:
#          rclone sync of the export dir to the remote, pinging
#          healthchecks.io (/start … success | /fail).
#
# `document_exporter` (not a volume copy): writes originals + metadata +
# manifest in a version-portable format restorable with `document_importer`.
# Deliberately unzipped: an unzipped export makes the rclone sync incremental
# (only changed files transfer); the exporter's --delete keeps it a clean
# mirror. The exporter stops the paperless services while it runs (upstream
# behavior), which is fine at 01:30.
#
# Failure handling — the part that matters for a token-expiring remote:
#   - export fails  → backup never runs → missed ping → healthchecks.io alert
#   - rclone fails  → /fail ping → immediate alert (catches token expiry)
#   - host is dead  → no ping → alert
#
# Setup:
#   1. Create a check "paperless-backup" at healthchecks.io (period 1 day,
#      grace 1h) and encrypt its ping URL into
#      secrets/sorbet/paperless-backup-ping (binary format, same shape as
#      secrets/sorbet/healthchecks).
#   2. Restore drill (a backup you've never restored is a guess): on a fresh
#      paperless instance run
#      `paperless-manage document_importer /media/data/Paperless-export`.
#
# Remote: rclone has no official iCloud Drive backend, so this syncs to the
# gdrive remote already present in secrets/sorbet/rclone (the navidrome
# backup's remote). To retarget, change `remote` and add the remote to that
# sops config.
_: {
  flake.nixosModules.paperlessBackup = {
    config,
    pkgs,
    ...
  }: let
    remote = "gdrive:paperless-backup";
    exportDir = "/media/data/Paperless-export";
  in {
    sops.secrets = {
      # Same rclone config as navidrome-gdrive-sync, rendered for the
      # paperless user.
      "rclone/paperless" = {
        sopsFile = ../secrets/sorbet/rclone;
        format = "binary";
        key = "";
        owner = "paperless";
      };

      "healthchecks/paperless-backup" = {
        sopsFile = ../secrets/sorbet/paperless-backup-ping;
        format = "binary";
        key = "";
        owner = "paperless";
        mode = "0400";
      };
    };

    services.paperless.exporter = {
      enable = true;
      directory = exportDir;
      onCalendar = "01:30:00";
      # Defaults kept: --no-progress-bar --no-color --compare-checksums
      # --delete. No --zip (would defeat the incremental sync).
    };

    # Push off-box only after a *successful* export; on export failure the
    # missed ping is the alert. Merges with upstream's OnSuccess (which
    # restarts the paperless services).
    systemd.services.paperless-exporter.onSuccess = ["paperless-backup.service"];

    systemd.services.paperless-backup = {
      description = "Push paperless export off-box via rclone + ping healthchecks.io";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        User = "paperless";
        ExecStart = pkgs.writeShellScript "paperless-backup" ''
          set -eu

          PING_URL=$(cat ${config.sops.secrets."healthchecks/paperless-backup".path})
          hc() {
            ${pkgs.curl}/bin/curl -fsS --max-time 10 --retry 3 "$1" >/dev/null
          }

          hc "$PING_URL/start" || true

          # --transfers 2 / --checkers 4: keep the request rate low so the
          # remote's rate limits don't trip on the nightly run.
          if ${pkgs.rclone}/bin/rclone sync \
            --config ${config.sops.secrets."rclone/paperless".path} \
            --fast-list --transfers 2 --checkers 4 \
            ${exportDir} "${remote}"
          then
            hc "$PING_URL"
          else
            status=$?
            hc "$PING_URL/fail" || true
            exit "$status"
          fi
        '';
      };
    };
  };
}
