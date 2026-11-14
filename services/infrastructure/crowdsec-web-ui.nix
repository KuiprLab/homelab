{config, ...}: let
  # Eclair's loopback carries this address so the pangolin tunnel can reach the
  # LAPI without an alias, which would drag the client into DNS.
  lapiTunnelAddress = "10.90.0.1";
  vhost = config.flake.pangolinVirtualHosts."crowdsec";
  healthFlags = config.flake.healthFlags;
  labels =
    config.flake.pangolinRuleLabels "crowdsec"
    // config.flake.pangolinHealthcheckLabels "crowdsec" vhost
    // config.flake.pangolinPublicLabels "crowdsec" vhost;
in {
  flake = {
    pangolinVirtualHosts."crowdsec" = {
      site = "sorbet";
      name = "CrowdSec";
      subdomain = "crowdsec.ext.kuipr.de";
      port = 3010;
      private = false;
      # host networking: the vhost points at loopback, the labels live on the container
      extra.auth = {
        "sso-enabled" = true;
        "sso-roles" = ["Member"];
      };
    };

    # Private host resource: reachable only by pangolin clients granted access.
    pangolinHostResources."lapi" = {
      site = "eclair";
      name = "CrowdSec LAPI (eclair)";
      destination = lapiTunnelAddress;
      tcpPorts = "9090,6060";
    };

    nixosModules.crowdsecWebUi = {config, ...}: {
      sops.secrets."crowdsec-web-ui" = {
        sopsFile = ../../secrets/shared/crowdsec-web-ui.env;
        format = "dotenv";
        key = "";
        owner = "root";
        restartUnits = ["podman-crowdsec-web-ui.service"];
      };

      virtualisation.oci-containers.containers.crowdsec-web-ui = {
        inherit labels;
        image = "ghcr.io/theduffman85/crowdsec-web-ui:2026.11.11@sha256:b2c4e13d1a36ab306db090d58efb54ab347ea5616c81badcb5bd8055e5dc4c2c";
        volumes = ["/var/lib/crowdsec-web-ui:/app/data:rw"];

        environment = {
          CONFIG_AUTH_ENABLED = "false";

          CONFIG_SERVER_PORT = "3010";

          CONFIG_INSTANCES_0_ID = "eclair";
          CONFIG_INSTANCES_0_NAME = "Eclair";
          CONFIG_INSTANCES_0_LAPI_URL = "http://${lapiTunnelAddress}:9090";
          CONFIG_INSTANCES_0_LAPI_AUTH_USERNAME = "crowdsec-web-ui";
          CONFIG_INSTANCES_0_METRICS_0_ID = "lapi";
          CONFIG_INSTANCES_0_METRICS_0_NAME = "Eclair LAPI";
          CONFIG_INSTANCES_0_METRICS_0_URL = "http://${lapiTunnelAddress}:6060/metrics";
        };

        environmentFiles = [
          "${config.sops.secrets."crowdsec-web-ui".path}"
        ];

        log-driver = "journald";

        extraOptions =
          [
            "--network=host"
            # Podman does not inherit image HEALTHCHECKs and the image has no curl.
          ]
          ++ healthFlags {
            cmd = "node -e \"const t=Date.now();(async()=>{while(Date.now()-t<25e3){try{if((await fetch('http://127.0.0.1:3010/api/health')).ok)return}catch(e){}await new Promise(r=>setTimeout(r,2e3))}process.exit(1)})()\"";
            startPeriod = "30s";
            timeout = "30s";
          };
      };

      systemd = {
        tmpfiles.rules = [
          # uid 1000 is the image's node user and happens to be `daniel` on sorbet.
          "d /var/lib/crowdsec-web-ui 0755 1000 100 -"
        ];

        # Ordering only: a tunnel restart must not take the container down.
        services.podman-crowdsec-web-ui = {
          after = ["pangolin-client.service"];
          wants = ["pangolin-client.service"];
        };
      };
    };

    eclairNixosModules.crowdsecWebUi = {
      config,
      pkgs,
      ...
    }: let
      cscli = "${config.services.crowdsec.package}/bin/cscli";

      mkForwarder = port: {
        description = "Expose CrowdSec port ${toString port} on the tunnel address";
        wantedBy = ["multi-user.target"];
        after = ["crowdsec.service"];
        wants = ["crowdsec.service"];
        startLimitIntervalSec = 0;
        serviceConfig = {
          ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:${toString port},bind=${lapiTunnelAddress},fork,reuseaddr TCP:127.0.0.1:${toString port}";
          Restart = "always";
          RestartSec = 3;
        };
      };
    in {
      sops.secrets."crowdsec-web-ui" = {
        sopsFile = ../../secrets/shared/crowdsec-web-ui.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      networking.interfaces.lo.ipv4.addresses = [
        {
          address = lapiTunnelAddress;
          prefixLength = 32;
        }
      ];

      systemd.services = {
        crowdsec-tunnel-lapi = mkForwarder 9090;
        crowdsec-tunnel-metrics = mkForwarder 6060;
      };

      systemd.services.crowdsec-web-ui-machine = {
        description = "Register the CrowdSec Web UI as a CrowdSec machine";
        wantedBy = ["multi-user.target"];
        after = ["crowdsec.service" "sops-install-secrets.service"];
        wants = ["crowdsec.service"];
        path = [config.services.crowdsec.package];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          set -a
          . ${config.sops.secrets."crowdsec-web-ui".path}
          set +a

          if ${cscli} machines inspect crowdsec-web-ui >/dev/null 2>&1; then
            echo "machine crowdsec-web-ui already registered"
          else
            ${cscli} machines add crowdsec-web-ui \
              --password "$CONFIG_INSTANCES_0_LAPI_AUTH_PASSWORD" -f /dev/null
          fi
        '';
      };
    };
  };
}
