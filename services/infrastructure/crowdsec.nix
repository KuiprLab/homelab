# CrowdSec security engine + firewall bouncer for eclair.
#
# eclair is the public edge: pangolin's traefik terminates TLS for every
# *.ext.kuipr.de resource and the pangolin dashboard, so it is the one place
# where client IPs are still real. The agent parses traefik's access log (via
# the journal) plus sshd and the firewall bouncer drops banned sources in
# nftables — before traefik completes a handshake or sshd forks.
#
# Deliberately firewall-only: no Traefik bouncer plugin, no AppSec/WAF. Bans
# are L3/L4 drops, so there is no ban page/captcha and no in-band request
# inspection. AppSec used to hang off sorbet's caddy via forward_auth; that
# path is gone now that TLS terminates here.
#
# Uses the PR branch modules (see flake.nix input `nixpkgs-crowdsec`): the
# modules merged into nixpkgs are still broken (DynamicUser without
# StateDirectory, register script reading a /etc/crowdsec/config.yaml that
# nothing creates, LAPI disabled by default).
#
# Console enrollment: `secrets/eclair/crowdsec-console-enrollment` holds the
# token from the "Enroll command" button at
# https://app.crowdsec.net/security-engines?distribution=linux
# (create with `opsops encrypt secrets/eclair/crowdsec-console-enrollment`).
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
    # builds them into `bin/` and no longer does that install. Needed for
    # console enrollment to push anything back.
    crowdsecWithPlugins = pkgs.crowdsec.overrideAttrs (old: {
      postInstall =
        (old.postInstall or "")
        + ''
          install -D $out/bin/notification-* -t $out/libexec/crowdsec/plugins/
        '';
    });
  in {
    sops.secrets."crowdsec/console-enrollment" = {
      sopsFile = ../../secrets/eclair/crowdsec-console-enrollment;
      format = "binary";
      key = "";
      owner = "root";
    };

    services = {
      crowdsec = {
        package = crowdsecWithPlugins;
        enable = true;
        autoUpdateService = true;

        hub.collections = [
          "crowdsecurity/linux"
          # sshd acquisition below is useless without the ssh scenarios.
          "crowdsecurity/sshd"
          # Parses traefik's CLF access log lines.
          "crowdsecurity/traefik"
          # Scan/probe/brute-force scenarios for http (the traefik collection
          # only ships the parser + a few app-specific scenarios).
          "crowdsecurity/base-http-scenarios"
          # Never ban well-known crawlers/monitoring services: they are noisy
          # but legitimate, and a crawl ban on the public edge is a false
          # positive more often than not.
          "crowdsecurity/whitelist-good-actors"
        ];

        settings = {
          acquisitions = [
            {
              source = "journalctl";
              journalctl_filter = ["-u" "sshd.service"];
              labels.type = "syslog";
            }
            {
              # traefik runs in a container and logs its access log to stdout
              # (traefik_config.yml sets `accessLog = {}`), so journald holds it
              # — no log file to rotate or expose to the agent's user.
              # type MUST stay "syslog": the hub's s00-raw parser strips the
              # journalctl timestamp prefix for syslog-type sources, leaving
              # the bare CLF line the traefik parser expects.
              source = "journalctl";
              journalctl_filter = ["-u" "podman-traefik.service"];
              labels.type = "syslog";
            }
          ];

          console.enrollKeyFile = config.sops.secrets."crowdsec/console-enrollment".path;

          # The LAPI keeps its default 8080 out of the way of the stack's own
          # listeners. `cscli machines add --auto` and the bouncer's api_url
          # both derive from listen_uri.
          config.api.server.listen_uri = "127.0.0.1:9090";

          # Needed for `cscli console enroll` (the setup script runs
          # `cscli capi register` first, creating this file if absent).
          config.api.server.online_client.credentials_path = "/var/lib/crowdsec/data/online_api_credentials.yaml";
        };
      };

      crowdsec-firewall-bouncer = {
        enable = true;
        # Auto-register with the local LAPI; the API key is generated on the box.
        registerBouncer.enable = true;
        # settings.mode defaults to "nftables" once networking.nftables is
        # enabled. The module's generated rulesets build the drop rule without
        # nftables counters, so the bouncer has nothing to read its usage
        # metrics from (console "Traffic dropped" stays at zero). The tables
        # are declared below instead.
        createRulesets = false;
      };
    };

    networking.nftables.enable = true;

    # Rulesets for the bouncer's set-only mode (it only fills the sets, the
    # chains/rules are ours). Mirrors the module's createRulesets output, but
    # with the nftables named counters the bouncer reads its usage metrics
    # from: cs-firewall-bouncer's metrics collector sums counter objects named
    # `processed` (must be exactly that) and `crowdsec[6]-blacklists-*` — with
    # none present it reports dropped/processed = 0 and the console's
    # "Traffic dropped" widget stays empty. Enforcement semantics (hook input,
    # priority filter) are unchanged from the module's rulesets.
    networking.nftables.tables = {
      "crowdsec" = {
        family = "ip";
        content = ''
          set crowdsec-blacklists {
            type ipv4_addr
            flags timeout
          }

          counter crowdsec-blacklists-all { }
          counter processed { }

          chain crowdsec-chain {
            type filter hook input priority filter; policy accept;
            counter name processed
            ip saddr @crowdsec-blacklists counter name crowdsec-blacklists-all drop
          }
        '';
      };
      "crowdsec6" = {
        family = "ip6";
        content = ''
          set crowdsec6-blacklists {
            type ipv6_addr
            flags timeout
          }

          counter crowdsec6-blacklists-all { }
          counter processed { }

          chain crowdsec6-chain {
            type filter hook input priority filter; policy accept;
            counter name processed
            ip6 saddr @crowdsec6-blacklists counter name crowdsec6-blacklists-all drop
          }
        '';
      };
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

      # The PR module has no triggers: acquisition/collection changes only land
      # on disk (via crowdsec-setup) and the running agent keeps its old config.
      # Restart the agent when the acquisition or hub-collection config changes.
      crowdsec.restartTriggers = [
        (builtins.toJSON config.services.crowdsec.settings.acquisitions)
        (builtins.toJSON config.services.crowdsec.hub.collections)
      ];

      # The parser-stage whitelist (environment.etc below) only filters log
      # lines; decisions already in the LAPI bypass it. Keep an LAPI allowlist
      # for genuinely internal sources so infra traffic can never be banned:
      # loopback, link-local. Deliberately NOT blanket RFC1918/CGNAT — a
      # compromised LAN device must remain ban-able.
      crowdsec-internal-allowlist = {
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
          cscli allowlists create internal-ranges -d "loopback and link-local" 2>/dev/null || true
          ${lib.concatMapStringsSep "\n" (r: "cscli allowlists add internal-ranges ${r} -d 'local infra' 2>/dev/null || true") [
            "127.0.0.0/8"
            "169.254.0.0/16"
            "::1/128"
            "fe80::/10"
          ]}
        '';
      };
    };

    environment.etc."crowdsec/parsers/s01-whitelist/local-ranges.yaml" = {
      user = "crowdsec";
      group = "crowdsec";
      text = ''
        name: local/private-ranges
        description: "Loopback and link-local"
        # onsuccess: next_stage is REQUIRED: a whitelist node without it
        # "succeeds" but never advances the event, so every non-whitelisted
        # line aborts at this stage and no scenario ever sees it.
        onsuccess: next_stage
        whitelist:
          reason: "local infrastructure ranges"
          cidr:
            - "127.0.0.0/8"
            - "169.254.0.0/16"
            - "::1/128"
            - "fe80::/10"
      '';
    };
  };
}
