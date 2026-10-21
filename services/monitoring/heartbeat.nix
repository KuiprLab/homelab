# Heartbeat / dead-man's switch via healthchecks.io.
#
# Each host runs a systemd timer that curls a unique check URL every 5 min.
# If a host is fully dead (power, kernel panic, lost network) and stops
# pinging, healthchecks.io alerts you out-of-band — gatus can't, because
# gatus runs on these same hosts.
#
# Setup:
#   1. Create two checks at https://healthchecks.io/ (one per host).
#      Suggested period: 5min, grace: 5min.
#   2. Configure Discord/email integration on the healthchecks.io account.
#   3. Encrypt the ping URL into the per-host sops file:
#      - secrets/sorbet/healthchecks  (raw URL, e.g. https://hc-ping.com/<uuid>)
#      - secrets/eclair/healthchecks  (raw URL, e.g. https://hc-ping.com/<uuid>)
#      Use the same age key already configured (.sops.yaml).
#
# The URL itself is the only auth token healthchecks.io uses, so we treat
# it as a secret to keep it out of git.
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
        # Use $(cat <secret>) to inline the URL. --max-time short so a
        # network blip doesn't hold up the timer; --retry handles transients.
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
        # Add small randomization so two hosts don't ping simultaneously
        # (helps healthchecks.io rate-limiting heuristics).
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
