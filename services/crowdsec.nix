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
    ...
  }: let
    # Console enrollment token, created by the user with
    # `sops secrets/eclair/crowdsec-console-enrollment`. Guarded so the host
    # still evaluates (and deploys, unenrolled) before that file exists.
    enrollmentTokenExists = builtins.pathExists ../../secrets/eclair/crowdsec-console-enrollment;
  in {
    sops.secrets = lib.optionalAttrs enrollmentTokenExists {
      "crowdsec/console-enrollment" = {
        sopsFile = ../../secrets/eclair/crowdsec-console-enrollment;
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

      settings.console.enrollKeyFile =
        if enrollmentTokenExists
        then config.sops.secrets."crowdsec/console-enrollment".path
        else null;
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
