# homelab-bot -- Discord bot for the lab.
#
# The package is built from source in this same directory (_package.nix), so
# one commit moves the bot's code and the unit that runs it together. That is
# the whole point of apps/ living in this repo rather than its own.
#
# Before first start:
#   1. Create an application at https://discord.com/developers/applications,
#      add a bot, copy the token and the application ID.
#   2. sops secrets/sorbet/homelab-bot.env   -- replace the placeholders.
#   3. Set `enabled = true` below.
#   4. Deploy sorbet. The bot registers its commands with Discord on startup,
#      so there is nothing else to run. homelab-bot-register stays available
#      for pushing a command change without restarting the bot.
#
# It ships disabled on purpose: until the secret holds a real token the bot
# cannot log in, and a running unit would just restart-loop.
{
  config,
  lib,
  pkgs,
  ...
}: let
  homelab-bot = pkgs.callPackage ./_package.nix {};

  # The single switch for this service. Flip to true once the Discord token in
  # secrets/sorbet/homelab-bot.env is real.
  #
  # This gates wantedBy AND the secret's restartUnits together, because the two
  # have to agree. sops-nix restarts every unit listed in restartUnits when the
  # secret changes, and `systemctl restart` STARTS an inactive unit -- wantedBy
  # does not protect it. Listing the unit while it was meant to stay down is
  # what put the placeholder token into a 30s restart loop against Discord's
  # login endpoint on the first deploy. One flag, so they cannot drift apart.
  enabled = true;

  # Both units run the same code, read the same secret and get the same
  # confinement -- only the entry point differs.
  common = {
    EnvironmentFile = config.sops.secrets."homelab-bot/env".path;

    # systemd reads EnvironmentFile as root before dropping privileges, so the
    # secret stays root-only even though the process itself is unprivileged.
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

    # The bot talks to Discord over HTTPS and nothing else. AF_NETLINK is not
    # optional despite that: glibc's resolver uses it to enumerate interfaces,
    # and DNS fails without it.
    RestrictAddressFamilies = ["AF_INET" "AF_INET6" "AF_UNIX" "AF_NETLINK"];

    # Deliberately NOT setting MemoryDenyWriteExecute: V8 maps pages
    # write-then-execute for JIT, and enabling it kills Node on startup.
  };
in {
  sops.secrets."homelab-bot/env" = {
    sopsFile = ../../secrets/sorbet/homelab-bot.env;
    format = "dotenv";
    key = "";

    # Once enabled, editing the token and deploying restarts the bot so it
    # actually picks the new value up. Empty while disabled -- see `enabled`.
    restartUnits = lib.optionals enabled ["homelab-bot.service"];
  };

  systemd.services = {
    homelab-bot = {
      description = "Discord bot for the homelab";
      documentation = ["https://github.com/KuiprLab/sorbet.nix"];

      wantedBy = lib.optionals enabled ["multi-user.target"];

      after = ["network-online.target"];
      wants = ["network-online.target"];

      serviceConfig =
        common
        // {
          ExecStart = lib.getExe homelab-bot;
          Restart = "on-failure";

          # Discord rate-limits login attempts, so back off rather than
          # hammering the gateway when the token is wrong.
          RestartSec = "30s";
        };
    };

    # Run by hand after changing the command list; registering is a rate
    # limited write to Discord's API, not something to do on every boot.
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
