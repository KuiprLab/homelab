_: {
  flake = {
    pangolinVirtualHosts."crowdsec" = {
      site = "sorbet";
      name = "CrowdSec";
      subdomain = "crowdsec.ext.kuipr.de";
      port = 3010;
      private = false;
      extra.auth = {
        "sso-enabled" = true;
        "sso-roles" = ["Member"];
      };
    };

    nixosModules.crowdsecWebUi = {
      config,
      lib,
      pkgs,
      ...
    }: {
      sops.secrets."crowdsec-web-ui" = {
        sopsFile = ../../secrets/shared/crowdsec-web-ui.env;
        format = "dotenv";
        key = "";
        owner = "root";
        restartUnits = ["podman-crowdsec-web-ui.service"];
      };

      # Key for the loopback forward into eclair; the public half is restricted in eclair's authorized_keys.
      sops.secrets."crowdsec-lapi-tunnel.key" = {
        sopsFile = ../../secrets/sorbet/crowdsec-lapi-tunnel.key;
        format = "binary";
        key = "";
        owner = "root";
        mode = "0400";
      };

      environment.etc."crowdsec-lapi-tunnel/known_hosts".text = ''
        eclair.kuipr.de ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOV5Cly7esQDTdNmO0SsgHagaaewbWZeF4g86i17HsJc
      '';

      # ExitOnForwardFailure: a half-open tunnel must not look healthy.
      systemd.services.crowdsec-lapi-tunnel = {
        description = "SSH forward to eclair's CrowdSec LAPI";
        wantedBy = ["multi-user.target"];
        after = ["network-online.target"];
        wants = ["network-online.target"];
        serviceConfig = {
          Restart = "always";
          RestartSec = "10s";
          Environment = ["HOME=/root"];
          ExecStart = lib.concatStringsSep " " [
            "${pkgs.openssh}/bin/ssh"
            "-N"
            "-i ${config.sops.secrets."crowdsec-lapi-tunnel.key".path}"
            "-o IdentitiesOnly=yes"
            "-o BatchMode=yes"
            "-o StrictHostKeyChecking=yes"
            "-o UserKnownHostsFile=/etc/crowdsec-lapi-tunnel/known_hosts"
            "-o GlobalKnownHostsFile=/dev/null"
            "-o UpdateHostKeys=no"
            "-o ServerAliveInterval=15"
            "-o ServerAliveCountMax=3"
            "-o ExitOnForwardFailure=yes"
            "-L 127.0.0.1:19090:127.0.0.1:9090"
            "-L 127.0.0.1:19091:127.0.0.1:6060"
            "root@eclair.kuipr.de"
          ];
        };
      };

      virtualisation.oci-containers.containers.crowdsec-web-ui = {
        image = "ghcr.io/theduffman85/crowdsec-web-ui:2026.10.12@sha256:c653e0411627ef92d57108129c30bbeac21a421eff272d0e2aa4f8dcb5743e2d";
        volumes = ["/var/lib/crowdsec-web-ui:/app/data:rw"];

        environment = {
          CONFIG_AUTH_ENABLED = "false";

          CONFIG_SERVER_PORT = "3010";

          CONFIG_INSTANCES_0_ID = "eclair";
          CONFIG_INSTANCES_0_NAME = "Eclair";
          CONFIG_INSTANCES_0_LAPI_URL = "http://127.0.0.1:19090";
          CONFIG_INSTANCES_0_LAPI_AUTH_USERNAME = "crowdsec-web-ui";
          CONFIG_INSTANCES_0_METRICS_0_ID = "lapi";
          CONFIG_INSTANCES_0_METRICS_0_NAME = "Eclair LAPI";
          CONFIG_INSTANCES_0_METRICS_0_URL = "http://127.0.0.1:19091/metrics";
        };

        environmentFiles = [
          "${config.sops.secrets."crowdsec-web-ui".path}"
        ];

        log-driver = "journald";

        extraOptions = [
          "--network=host"
          # Podman does not inherit image HEALTHCHECKs and the image has no curl.
          "--health-cmd=node -e \"const t=Date.now();(async()=>{while(Date.now()-t<25e3){try{if((await fetch('http://127.0.0.1:3010/api/health')).ok)return}catch(e){}await new Promise(r=>setTimeout(r,2e3))}process.exit(1)})()\""
          "--health-interval=30s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=30s"
          "--health-timeout=30s"
        ];
      };

      systemd = {
        tmpfiles.rules = [
          # uid 1000 is the image's node user and happens to be `daniel` on sorbet.
          "d /var/lib/crowdsec-web-ui 0755 1000 100 -"
        ];

        # Ordering only: a tunnel restart must not take the container down.
        services.podman-crowdsec-web-ui = {
          after = ["crowdsec-lapi-tunnel.service"];
          wants = ["crowdsec-lapi-tunnel.service"];
        };
      };
    };

    eclairNixosModules.crowdsecWebUi = {config, ...}: let
      cscli = "${config.services.crowdsec.package}/bin/cscli";
    in {
      sops.secrets."crowdsec-web-ui" = {
        sopsFile = ../../secrets/shared/crowdsec-web-ui.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      # restrict drops pty, agent/X11 forwarding and command execution.
      users.users.root.openssh.authorizedKeys.keys = [
        ''restrict,port-forwarding,permitopen="127.0.0.1:9090",permitopen="127.0.0.1:6060" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKHrJy0LptdihGPCHzzNivs4RkmTkkozzByaKqw2oR3N crowdsec-lapi-tunnel@sorbet''
      ];

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
