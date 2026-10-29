# Uses the nixpkgs-crowdsec PR branch; the merged nixpkgs modules are still broken.
_: {
  flake.eclairNixosModules.crowdsec = {
    config,
    lib,
    pkgs,
    ...
  }: let
    # nixpkgs' crowdsec 1.8.1 builds notification plugins into bin/, the module expects libexec/.
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
          "crowdsecurity/sshd"
          "crowdsecurity/traefik"
          "crowdsecurity/base-http-scenarios"
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
              # type MUST stay "syslog": the s00-raw parser strips the journalctl prefix.
              source = "journalctl";
              journalctl_filter = ["-u" "podman-traefik.service"];
              labels.type = "syslog";
            }
          ];

          console.enrollKeyFile = config.sops.secrets."crowdsec/console-enrollment".path;

          config.api.server.listen_uri = "127.0.0.1:9090";

          config.api.server.online_client.credentials_path = "/var/lib/crowdsec/data/online_api_credentials.yaml";
        };
      };

      crowdsec-firewall-bouncer = {
        enable = true;
        registerBouncer.enable = true;
        # Module rulesets have no counters, so the bouncer's metrics stay at zero.
        createRulesets = false;
      };
    };

    networking.nftables.enable = true;

    # Counter names must be `processed` and `crowdsec[6]-blacklists-*` for the metrics collector.
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

    # The module gives each service its own DynamicUser; files written with UMask 0077 become unreadable.
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

      # The PR module has no triggers; acquisition/collection changes need a restart.
      crowdsec.restartTriggers = [
        (builtins.toJSON config.services.crowdsec.settings.acquisitions)
        (builtins.toJSON config.services.crowdsec.hub.collections)
      ];

      # Deliberately not RFC1918: a compromised LAN device must stay ban-able.
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
