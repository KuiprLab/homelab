_: {
  flake.nixosModules.paperlessBackup = {
    config,
    lib,
    pkgs,
    ...
  }: let
    remotes = [
      "gdrive:paperless-backup"
    ];
    exportDir = "/media/data/Paperless-export";
    # Must match the web container's image: the exporter has to run the code that wrote the DB.
    image = "ghcr.io/paperless-ngx/paperless-ngx:latest@sha256:9bc6e8248891bcfa6f52fffe8b81e4ea8cae75790c3ec1b9906961a7ba55c969";
    dataDir = "/var/lib/paperless";
    mediaDir = "/media/data/data/Paperless-data";
    # Written by the retired nixpkgs module; the image's s6 init refuses to start without it.
    secretKeyFile = "${dataDir}/nixos-paperless-secret-key.env";
    # rclone writes refreshed OAuth tokens back to its config; the sops file is read-only.
  in {
    sops.secrets = {
      "rclone/paperless" = {
        sopsFile = ../../secrets/sorbet/rclone;
        format = "binary";
        key = "";
        owner = "paperless";
      };

      "healthchecks/paperless-backup" = {
        sopsFile = ../../secrets/sorbet/paperless-backup-ping;
        format = "binary";
        key = "";
        owner = "paperless";
        mode = "0400";
      };
    };

    systemd = {
      services.paperless-exporter = {
        description = "Export paperless-ngx documents for the off-box backup";
        after = ["podman-paperless.service"];
        # --no-thumbnail: one webp per document makes the sync pathologically slow.
        script = ''
          set -eu
          exec ${pkgs.podman}/bin/podman run --rm \
            --network podman \
            -e USERMAP_UID=${toString config.users.users.paperless.uid} \
            -e USERMAP_GID=${toString config.users.groups.paperless.gid} \
            -e PAPERLESS_REDIS=redis://redis:6379 \
            -e PAPERLESS_DBENGINE=sqlite \
            -e PAPERLESS_SECRET_KEY \
            -v ${dataDir}:/usr/src/paperless/data \
            -v ${mediaDir}:/usr/src/paperless/media \
            -v ${exportDir}:/usr/src/paperless/export \
            ${image} \
            document_exporter ../export \
              --no-thumbnail --no-progress-bar --no-color --compare-checksums --delete
        '';
        serviceConfig = {
          Type = "oneshot";
          # Rootful podman; the container itself runs as the paperless uid.
          User = "root";
          EnvironmentFile = [secretKeyFile];
        };
        onSuccess = ["paperless-backup.service"];
      };

      timers.paperless-exporter = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "01:30:00";
          Persistent = true;
        };
      };

      services.paperless-backup = {
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

            # Low request rate so the remotes' rate limits don't trip.
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
  };
}
