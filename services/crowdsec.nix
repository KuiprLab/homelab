# CrowdSec security engine + firewall bouncer for eclair.
# Replaces the previous fail2ban setup.
#
# The agent detects attacks from sshd and haproxy journal logs; the
# firewall bouncer enforces bans via nftables — blocking before haproxy
# ever sees the connection (TCP-mode haproxy can't use a lua/SPOE bouncer).
#
# Uses the PR branch modules (see flake.nix input `nixpkgs-crowdsec`):
# the modules merged into nixpkgs are still broken (DynamicUser without
# StateDirectory, register script reading a /etc/crowdsec/config.yaml that
# nothing creates, LAPI disabled by default).
#
# Console enrollment: `secrets/eclair/crowdsec-console-enrollment` holds the
# token from the "Enroll command" button at
# https://app.crowdsec.net/security-engines?distribution=linux
# (create with `sops secrets/eclair/crowdsec-console-enrollment`).
# It is handed to the agent via LoadCredential; on start the agent enrolls
# itself as eclair, so decisions from the CrowdSec console (including
# community blocklists) are enforced locally too.
_: {
  flake.eclairNixosModules.crowdsec = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # The PR module's setup script installs the notification plugins from
    # `${package}/libexec/crowdsec/plugins/`, but nixpkgs' crowdsec 1.8.1
    # builds them into `bin/` and no longer does that install (the PR branch's
    # own package did, which is what the module was written against).
    crowdsecWithPlugins = pkgs.crowdsec.overrideAttrs (old: {
      postInstall =
        (old.postInstall or "")
        + ''
          install -D $out/bin/notification-* -t $out/libexec/crowdsec/plugins/
        '';
    });
  in {
    services.crowdsec.package = crowdsecWithPlugins;
    sops.secrets = {
      "crowdsec/console-enrollment" = {
        sopsFile = ../secrets/eclair/crowdsec-console-enrollment;
        format = "binary";
        key = "";
        owner = "root";
      };
    };

    services.crowdsec = {
      enable = true;
      autoUpdateService = true;

      hub.collections = [
        "crowdsecurity/linux"
        "crowdsecurity/haproxy"
      ];

      settings.acquisitions = [
        {
          source = "journalctl";
          journalctl_filter = ["-u" "sshd.service"];
          labels.type = "syslog";
        }
        {
          source = "journalctl";
          journalctl_filter = ["-u" "haproxy.service"];
          labels.type = "haproxy";
        }
      ];

      settings.console.enrollKeyFile = config.sops.secrets."crowdsec/console-enrollment".path;

      # eclair's caddy binds *:8080 for its global http port (ACME), so the
      # LAPI can't use its default 127.0.0.1:8080. Everything derives from
      # this: `cscli machines add --auto` writes credentials with
      # http://<listen_uri>, and the bouncer's api_url default follows it too.
      settings.config.api.server.listen_uri = "127.0.0.1:9090";
    };

    # The module runs every crowdsec service under its own DynamicUser (all
    # named `crowdsec`, but with different transient uids). Files written by
    # one service with UMask 0077 — e.g. the hub content installed by
    # crowdsec-setup — are then unreadable by the agent. Pin everything to a
    # real static user instead so all services share one identity.
    users.users.crowdsec = {
      isSystemUser = true;
      group = "crowdsec";
    };
    users.groups.crowdsec = {};

    systemd.services = {
      crowdsec.serviceConfig.DynamicUser = lib.mkForce false;
      crowdsec-setup.serviceConfig.DynamicUser = lib.mkForce false;
      crowdsec-update-hub.serviceConfig.DynamicUser = lib.mkForce false;
      crowdsec-firewall-bouncer.serviceConfig.DynamicUser = lib.mkForce false;
      crowdsec-firewall-bouncer-register.serviceConfig.DynamicUser = lib.mkForce false;
    };

    services.crowdsec-firewall-bouncer = {
      enable = true;
      # Auto-register with the local LAPI; the API key is generated on the box.
      registerBouncer.enable = true;
      # settings.mode defaults to "nftables" once networking.nftables is enabled.
    };

    # Switches the firewall backend to nftables, which the bouncer's
    # rulesets (tables "crowdsec"/"crowdsec6") hook into.
    networking.nftables.enable = true;
  };
}
