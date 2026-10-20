# CrowdSec Web UI — dashboard for eclair's CrowdSec engine.
#
# eclair-only: the LAPI listens on 127.0.0.1:9090 there (see
# services/infrastructure/crowdsec.nix) and is not exposed anywhere else.
#
# Networking — the container runs with --network=host, not on a podman bridge.
# Both reasons follow from the loopback-bound LAPI:
#   - a bridge container has no route to the host's 127.0.0.1;
#   - over host networking the dashboard's LAPI requests carry a 127.0.0.1
#     source address, which is what CrowdSec's api.server.trusted_ips gates
#     alert deletion on (upstream README: "Trusted IPs for Alert Deletion" —
#     a machine registration authenticates, it does not grant deletion).
# Port 3000 is deliberately absent from networking.firewall: the only way in
# is pangolin's traefik → eclair's newt → 127.0.0.1:3000.
#
# Auth — OIDC against Authelia, plus the local password login as a fallback.
# Authelia runs on sorbet, so OIDC-only would lock us out of the dashboard of
# the edge box that is still up. Authelia's group `admin` grants dashboard
# administrator, unmatched users are denied. The Authelia client
# (`crowdsec-web-ui` in secrets/sorbet/authelia/configuration.yml) must stay
# in sync with the CONFIG_AUTH_OIDC_* values below, including the redirect
# URI, which the app derives from X-Forwarded-Proto/-Host.
#
# LAPI credentials — one sops dotenv file feeds both the container
# (`--env-file`) and the registration oneshot, which sources the same
# CONFIG_ variable. Rotating the password requires deleting the machine
# record first (`cscli machines delete crowdsec-web-ui`) — the oneshot only
# adds a missing machine and never resets an existing one.
_: {
  flake = {
    pangolinVirtualHosts."crowdsec" = {
      site = "eclair";
      name = "CrowdSec";
      subdomain = "crowdsec.ext.kuipr.de";
      port = 3010;
      private = false;
    };

    eclairNixosModules.crowdsecWebUi = {config, ...}: let
      cscli = "${config.services.crowdsec.package}/bin/cscli";
    in {
      sops.secrets."crowdsec-web-ui" = {
        sopsFile = ../../secrets/eclair/crowdsec-web-ui.env;
        format = "dotenv";
        key = "";
        owner = "root";
        restartUnits = ["podman-crowdsec-web-ui.service"];
      };

      virtualisation.oci-containers.containers.crowdsec-web-ui = {
        image = "ghcr.io/theduffman85/crowdsec-web-ui:2026.10.8@sha256:1e7ef2ddb701c8610301787c9ed476b57184ec5f5e839db804fbb4da3dccc17f";
        volumes = ["/var/lib/crowdsec-web-ui:/app/data:rw"];

        # Non-secret config. The LAPI password and the OIDC client secret are
        # the only CONFIG_ secrets and arrive through environmentFiles below.
        environment = {
          # 3000 belongs to pangolin's own server on this host; anything
          # sharing the host network namespace has to pick its own port.
          CONFIG_SERVER_PORT = "3010";

          CONFIG_INSTANCES_0_ID = "eclair";
          CONFIG_INSTANCES_0_NAME = "Eclair";
          CONFIG_INSTANCES_0_LAPI_URL = "http://127.0.0.1:9090";
          CONFIG_INSTANCES_0_LAPI_AUTH_USERNAME = "crowdsec-web-ui";
          # CrowdSec already scrapes itself (prometheus.enabled, level full in
          # /etc/crowdsec/config.yaml) — this is what fills the Metrics tab.
          CONFIG_INSTANCES_0_METRICS_0_ID = "lapi";
          CONFIG_INSTANCES_0_METRICS_0_NAME = "Eclair LAPI";
          CONFIG_INSTANCES_0_METRICS_0_URL = "http://127.0.0.1:6060/metrics";

          CONFIG_AUTH_OIDC_ISSUER_URL = "https://auth.ext.kuipr.de";
          CONFIG_AUTH_OIDC_CLIENT_ID = "crowdsec-web-ui";
          # `groups` is an Authelia scope that emits the groups claim; without
          # it every user would resolve to unmatchedRole.
          CONFIG_AUTH_OIDC_SCOPE = "openid profile email groups";
          CONFIG_AUTH_OIDC_GROUPS_CLAIM = "groups";
          # YAML array, not a bare string — the app parses CONFIG_ values as
          # YAML and rejects a scalar here.
          CONFIG_AUTH_OIDC_ADMIN_GROUPS = "[admin]";
          CONFIG_AUTH_OIDC_UNMATCHED_ROLE = "deny";
        };

        environmentFiles = [
          "${config.sops.secrets."crowdsec-web-ui".path}"
        ];

        log-driver = "journald";

        extraOptions = [
          # See the header: reach the loopback LAPI and appear as 127.0.0.1.
          "--network=host"
          # Podman does not inherit image HEALTHCHECKs, and the image has no
          # curl — mirror the upstream probe with node. Retry inside the
          # command: podman's first check fires immediately at start, and a
          # failed transient-unit check aborts NixOS activations.
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
          # Container runs as the image's node user (uid/gid 1000).
          "d /var/lib/crowdsec-web-ui 0755 1000 100 -"
        ];

        # The dashboard authenticates to LAPI as a registered machine. Watch
        # (never bouncer) credentials, so it can read alerts and manage
        # decisions without joining the enforcement path.
        services.crowdsec-web-ui-machine = {
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
            # Shared with the container above: both read this variable.
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

        # No dashboard login before its machine credentials exist.
        services.podman-crowdsec-web-ui = {
          after = ["crowdsec-web-ui-machine.service"];
          wants = ["crowdsec-web-ui-machine.service"];
        };
      };
    };
  };
}
