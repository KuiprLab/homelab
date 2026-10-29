{
  config,
  lib,
  pkgs,
  ...
}: let
  homelab-bot = pkgs.callPackage ./_package.nix {nodejs = pkgs.nodejs_26;};

  hintsDir = "/var/lib/beets-hints";

  # Outside /home on purpose: ProtectHome=true tmpfs hides bind mounts beneath it.
  beetsLibrarySource = "/home/daniel/.beets/library.db";
  beetsLibrary = "/var/lib/beets-library.db";

  retagDir = "/var/lib/beets-retag";

  # Not the vhost: that sits behind authelia and answers API calls with a login page.
  gatusUrl = "http://127.0.0.1:8888";

  # Same flag gates restartUnits: systemctl restart STARTS an inactive unit.
  enabled = true;

  common = {
    EnvironmentFile = config.sops.secrets."homelab-bot/env".path;

    DynamicUser = true;

    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    ProtectProc = "invisible";
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    CapabilityBoundingSet = [""];
    SystemCallArchitectures = "native";
    SystemCallFilter = ["@system-service" "~@privileged"];

    # AF_NETLINK is not optional: the glibc resolver needs it to list interfaces.
    RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK"];

    # No MemoryDenyWriteExecute: V8 JIT maps pages write-then-execute.
  };
in {
  sops.secrets."homelab-bot/env" = {
    sopsFile = ../../secrets/sorbet/homelab-bot.env;
    format = "dotenv";
    key = "";

    restartUnits = lib.optionals enabled ["homelab-bot.service"];
  };

  # 2775: setgid so hints stay readable by daniel, group-writable for cleanup.
  systemd.tmpfiles.rules = [
    "d ${hintsDir} 2775 daniel users - -"
    "d ${retagDir} 2775 daniel users - -"
  ];

  systemd.services = {
    homelab-bot = {
      description = "Discord bot for the homelab";
      documentation = ["https://github.com/KuiprLab/sorbet.nix"];

      wantedBy = lib.optionals enabled ["multi-user.target"];

      after = ["network-online.target"];
      wants = ["network-online.target"];

      environment = {
        BEETS_HINTS_DIR = hintsDir;
        BEETS_LIBRARY = beetsLibrary;
        BEETS_RETAG_DIR = retagDir;
        GATUS_URL = gatusUrl;
      };

      serviceConfig =
        common
        // {
          ExecStart = lib.getExe homelab-bot;
          Restart = "on-failure";

          # Not StateDirectory: with DynamicUser that is 0700 root-only.
          ReadWritePaths = [hintsDir retagDir];

          BindReadOnlyPaths = ["${beetsLibrarySource}:${beetsLibrary}"];

          SupplementaryGroups = ["users"];

          # Discord rate-limits logins: back off instead of hammering the gateway.
          RestartSec = "30s";
        };
    };

    # Run by hand after a command change; registering is a rate-limited write.
    homelab-bot-register = {
      description = "Register homelab-bot slash commands with Discord";
      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig =
        common
        // {
          Type = "oneshot";
          ExecStart = lib.getExe' homelab-bot "homelab-bot-register";
        };
    };
  };
}
