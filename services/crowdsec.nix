# CrowdSec security engine + firewall bouncer + AppSec (WAF) for eclair.
# Replaces the previous fail2ban setup.
#
# The agent detects attacks from sshd, haproxy and caddy journal logs; the
# firewall bouncer enforces bans via nftables — blocking before haproxy
# ever sees the connection (TCP-mode haproxy can't use a lua/SPOE bouncer).
# On top of that, the AppSec engine (same agent process, listener on
# 127.0.0.1:7422) inspects every request that caddy forwards to it and
# blocks WAF rule matches in-band (see eclair-caddy.nix).
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
        "crowdsecurity/caddy"
        # AppSec rule sets pulled in as dependencies of the appsec-default
        # config (virtual-patching = CVE rules, generic = SQLi/RCE/LFI/etc.).
        "crowdsecurity/appsec-virtual-patching"
        "crowdsecurity/appsec-generic-rules"
      ];

      hub.appsec-configs = ["crowdsecurity/appsec-default"];

      settings.acquisitions = [
        {
          source = "journalctl";
          journalctl_filter = ["-u" "sshd.service"];
          labels.type = "syslog";
        }
        {
          # type MUST be "syslog": the hub's s00-raw parser strips the
          # journalctl timestamp prefix for syslog-type sources, leaving
          # the clean haproxy line its grok patterns expect. With any
          # other type the prefix stays in the message and nothing parses.
          source = "journalctl";
          journalctl_filter = ["-u" "haproxy.service"];
          labels.type = "syslog";
        }
        {
          # caddy's JSON access logs (see eclair-caddy.nix); with PROXY
          # protocol from haproxy these carry real client IPs.
          # type MUST stay "syslog": the hub's s00-raw parser strips the
          # journalctl timestamp prefix for syslog-type sources, leaving
          # the pure JSON message the caddy-logs parser needs. With any
          # other type the message keeps its prefix and fails to parse.
          source = "journalctl";
          journalctl_filter = ["-u" "caddy.service"];
          labels.type = "syslog";
        }
        {
          # CrowdSec AppSec (WAF): caddy forwards every request to this
          # listener (forward_auth in eclair-caddy.nix); in-band rule matches
          # answer 403, matches also feed the usual scenario pipeline.
          # Requests must carry a bouncer API key — registered for caddy by
          # crowdsec-caddy-appsec-register.service below.
          source = "appsec";
          listen_addr = "127.0.0.1:7422";
          appsec_config = "crowdsecurity/appsec-default";
          labels.type = "appsec";
        }
      ];

      settings.console.enrollKeyFile = config.sops.secrets."crowdsec/console-enrollment".path;

      # eclair's caddy binds *:8080 for its global http port (ACME), so the
      # LAPI can't use its default 127.0.0.1:8080. Everything derives from
      # this: `cscli machines add --auto` writes credentials with
      # http://<listen_uri>, and the bouncer's api_url default follows it too.
      settings.config.api.server.listen_uri = "127.0.0.1:9090";

      # Needed for `cscli console enroll` (the setup script then runs
      # `cscli capi register` first, creating this file if absent).
      settings.config.api.server.online_client.credentials_path = "/var/lib/crowdsec/data/online_api_credentials.yaml";
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

    # Whitelist internal ranges so infra traffic (haproxy→caddy hops, gatus
    # health checks, tailnet management access) can never generate alerts or
    # bans — the v0.0.36 firewall bouncer itself has no whitelist option, so
    # this happens at the agent's parse stage.
    environment.etc."crowdsec/parsers/s01-whitelist/local-ranges.yaml" = {
      user = "crowdsec";
      group = "crowdsec";
      text = ''
        name: local/private-ranges
        description: "Loopback, RFC1918, link-local and tailnet ranges"
        whitelist:
          reason: "local infrastructure ranges"
          cidr:
            - "127.0.0.0/8"
            - "10.0.0.0/8"
            - "172.16.0.0/12"
            - "192.168.0.0/16"
            - "169.254.0.0/16"
            - "100.64.0.0/10"
            - "::1/128"
            - "fe80::/10"
            - "fc00::/7"
      '';
    };

    # The PR module has no triggers: acquisition/collection changes only land
    # on disk (via crowdsec-setup) and the running agent keeps its old config.
    # Restart the agent when the acquisition or hub-collection config changes.
    systemd.services.crowdsec.restartTriggers = [
      (builtins.toJSON config.services.crowdsec.settings.acquisitions)
      (builtins.toJSON config.services.crowdsec.hub.collections)
      (builtins.toJSON config.services.crowdsec.hub.appsec-configs)
    ];

    # AppSec requests must carry a bouncer API key (validated against the
    # LAPI), so caddy needs one. Mirror the firewall-bouncer's registration
    # pattern: register `caddy-appsec` on first boot and drop the key into
    # an env-file that caddy's systemd service reads via
    # services.caddy.environmentFile (see eclair-caddy.nix).
    systemd.services.crowdsec-caddy-appsec-register = {
      description = "Register the caddy-appsec bouncer to the local CrowdSec service";
      wantedBy = ["multi-user.target"];
      after = ["crowdsec.service"];
      wants = ["crowdsec.service"];
      path = [config.services.crowdsec.package];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = let
        apiKeyFile = "/var/lib/crowdsec-caddy-appsec/api-key.env";
      in ''
        mkdir -p "$(dirname ${apiKeyFile})"
        if cscli bouncers list --output json | ${lib.getExe pkgs.jq} -e 'any(.[]; .name == "caddy-appsec")' >/dev/null; then
          if [ -s ${apiKeyFile} ]; then
            echo "caddy-appsec registered, key file present"
            exit 0
          fi
          echo "caddy-appsec registered but key file missing; re-registering"
          cscli bouncers delete caddy-appsec || true
        fi
        echo "CADDY_APPSEC_KEY=$(cscli bouncers add --output raw caddy-appsec)" > ${apiKeyFile}
        chmod 0600 ${apiKeyFile}
      '';
    };

    # The parser-stage whitelist (environment.etc above) only filters log
    # lines — AppSec bans bypass it. The LAPI allowlist is enforced at
    # alert/decision ingestion and synced into the AppSec engine, so local
    # infra traffic can never get banned by WAF rules either.
    systemd.services.crowdsec-internal-allowlist = {
      description = "Ensure the CrowdSec LAPI allowlist covers internal ranges";
      wantedBy = ["multi-user.target"];
      after = ["crowdsec.service"];
      wants = ["crowdsec.service"];
      path = [config.services.crowdsec.package];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        cscli allowlists create internal-ranges -d "local infrastructure ranges" 2>/dev/null || true
        ${lib.concatMapStringsSep "\n" (r: "cscli allowlists add internal-ranges ${r} -d 'local infra' 2>/dev/null || true") [
          "127.0.0.0/8"
          "10.0.0.0/8"
          "172.16.0.0/12"
          "192.168.0.0/16"
          "169.254.0.0/16"
          "100.64.0.0/10"
          "::1/128"
          "fe80::/10"
          "fc00::/7"
        ]}
      '';
    };

    # Switches the firewall backend to nftables, which the bouncer's
    # rulesets (tables "crowdsec"/"crowdsec6") hook into.
    networking.nftables.enable = true;
  };
}
