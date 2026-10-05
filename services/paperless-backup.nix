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
# Remotes: pushed to both, independently — one failing target doesn't
# block the other, and any failure trips the /fail ping:
#   - icloud (official rclone `iclouddrive` backend, needs rclone ≥ 1.69):
#     Apple trust tokens expire after 30 days — when that happens the sync
#     fails and the /fail ping alerts. Fix it on sorbet (2FA prompt arrives
#     on a trusted device, no sops surgery needed):
#       sudo -u paperless \
#         rclone reconnect icloud: --config /var/lib/paperless-backup/rclone.conf
#     Initial setup: interactively create the [icloud] remote and merge it
#     into secrets/sorbet/rclone (Apple ID password + 2FA; app-specific
#     passwords are NOT accepted):
#       rclone config   # storage: iclouddrive, service: drive
#     Documents end up unencrypted on Apple servers; add an rclone crypt
#     remote on top if that's a problem.
#   - gdrive: second copy that doesn't depend on the Apple login staying
#     healthy (already in secrets/sorbet/rclone).
_: {
  flake.nixosModules.paperlessBackup = {
    config,
    lib,
    pkgs,
    ...
  }: let
    remotes = [
      "icloud:Backups/Paperless"
      "gdrive:paperless-backup"
    ];
    exportDir = "/media/data/Paperless-export";
    # Writable copy of the sops-rendered rclone config: the iCloud backend
    # refreshes cookies/trust tokens in place between runs, which the
    # read-only sops file can't absorb. This also gives the reconnect
    # command above a stable config path.
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
        StateDirectory = "paperless-backup";
        ExecStart = pkgs.writeShellScript "paperless-backup" ''
          set -eu

          PING_URL=$(cat ${config.sops.secrets."healthchecks/paperless-backup".path})
          hc() {
            ${pkgs.curl}/bin/curl -fsS --max-time 10 --retry 3 "$1" >/dev/null
          }

          hc "$PING_URL/start" || true

          install -m 0600 ${config.sops.secrets."rclone/paperless".path} \
            /var/lib/paperless-backup/rclone.conf

          # --transfers 2 / --checkers 4: keep the request rate low so the
          # remotes' rate limits don't trip on the nightly run.
          failed=""
          for target in ${lib.escapeShellArgs remotes}; do
            if ! ${pkgs.rclone}/bin/rclone sync \
              --config /var/lib/paperless-backup/rclone.conf \
              --fast-list --transfers 2 --checkers 4 \
              ${exportDir} "$target"
            then
              echo "rclone sync to $target failed" >&2
              failed=1
            fi
          done

          if [ -n "$failed" ]; then
            hc "$PING_URL/fail" || true
            exit 1
          fi
          hc "$PING_URL"
        '';
      };
    };
  };
}
