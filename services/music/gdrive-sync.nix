# Navidrome backup sync to Google Drive via rclone
_: {
  flake.nixosModules.musicGdriveSync = {
    pkgs,
    config,
    ...
  }: {
    sops.secrets."rclone/config" = {
      sopsFile = ../../secrets/sorbet/rclone;
      format = "binary";
      key = "";
      owner = "navidrome";
    };

    systemd.services.navidrome-gdrive-sync = {
      description = "Sync Navidrome backups to Google Drive";
      startAt = "daily";
      serviceConfig = {
        Type = "oneshot";
        User = "navidrome";
        ExecStart = pkgs.writeShellScript "navidrome-gdrive-sync" ''
          ${pkgs.rclone}/bin/rclone sync \
            --config ${config.sops.secrets."rclone/config".path} \
            /var/lib/navidrome/backups \
            gdrive:navidrome-backups/
        '';
      };
    };
  };
}
