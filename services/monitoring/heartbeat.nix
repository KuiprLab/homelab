_: let
  mkHeartbeatModule = {sopsFile}: {
    config,
    pkgs,
    ...
  }: {
    sops.secrets."healthchecks/url" = {
      inherit sopsFile;
      format = "binary";
      key = "";
      owner = "root";
      mode = "0400";
    };

    systemd.services.heartbeat = {
      description = "Ping healthchecks.io dead-man's switch";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "heartbeat-ping" ''
          set -eu
          URL=$(cat ${config.sops.secrets."healthchecks/url".path})
          ${pkgs.curl}/bin/curl -fsS --max-time 10 --retry 3 \
            --user-agent "heartbeat/$(${pkgs.nettools}/bin/hostname)" \
            "$URL" >/dev/null
        '';
      };
    };

    systemd.timers.heartbeat = {
      description = "Trigger heartbeat ping every 5 minutes";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitActiveSec = "5min";
        RandomizedDelaySec = "30s";
        Persistent = true;
      };
    };
  };
in {
  flake.nixosModules.heartbeat =
    mkHeartbeatModule {sopsFile = ../../secrets/sorbet/healthchecks;};

  flake.eclairNixosModules.heartbeat =
    mkHeartbeatModule {sopsFile = ../../secrets/eclair/healthchecks;};
}
