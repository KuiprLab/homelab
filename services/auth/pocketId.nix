_: let
  proxyIp = "10.89.0.51";
in {
  flake = {
    podmanProxyHosts.pocketid.ip = proxyIp;

    pangolinVirtualHosts."pocketid" = {
      site = "sorbet";
      name = "PocketID";
      subdomain = "id.ext.kuipr.de";
      hostname = "pocketid";
      port = 1411;
      private = false;
    };

    nixosModules.pocketid = {
      pkgs,
      lib,
      config,
      ...
    }: let
      # The login link is single use and expires after an hour, so it is printed once instead of on every switch.
      runBootstrap =
        pkgs.writeShellScript "pocketid-bootstrap"
        /*
        bash
        */
        ''
          set -euo pipefail

          if [ -e "$BOOTSTRAP_MARKER" ]; then
            echo "login link already issued; delete $BOOTSTRAP_MARKER and restart pocketid-bootstrap to print a new one"
            exit 0
          fi

          attempt=0
          until podman exec pocketid /app/pocket-id healthcheck >/dev/null 2>&1; do
            attempt=$((attempt + 1))
            if [ "$attempt" -ge 60 ]; then
              echo "pocketid did not become healthy" >&2
              exit 1
            fi
            sleep 5
          done

          # The LDAP admin only exists after the first sync, so a failed lookup is retried instead of grepping the log.
          attempt=0
          until output=$(podman exec pocketid /app/pocket-id one-time-access-token "$POCKETID_ADMIN_USERNAME" 2>&1); do
            attempt=$((attempt + 1))
            if [ "$attempt" -ge 60 ]; then
              printf '%s\n' "$output" >&2
              echo "no LDAP user $POCKETID_ADMIN_USERNAME after 5 minutes; check the sync in podman-pocketid" >&2
              exit 1
            fi
            sleep 5
          done

          printf '%s\n' "$output"
          : >"$BOOTSTRAP_MARKER"
        '';
    in {
      sops.secrets = {
        "pocketid/pocketid.env" = {
          sopsFile = ../../secrets/sorbet/pocketid/pocketid.env;
          format = "dotenv";
          owner = "daniel";
          key = "";
          restartUnits = ["podman-pocketid.service" "pocketid-provision.service"];
        };
      };

      virtualisation.oci-containers.containers = {
        "pocketid" = {
          image = "docker.io/pocketid/pocket-id:v2";
          volumes = [
            "pocketid_data:/app/data:rw"
          ];
          environmentFiles = [
            "${config.sops.secrets."pocketid/pocketid.env".path}"
          ];
          environment = {
            LDAP_ADMIN_GROUP_NAME = "admin";
            LDAP_ATTRIBUTE_GROUP_NAME = "cn";
            LDAP_ATTRIBUTE_GROUP_UNIQUE_IDENTIFIER = "entryUUID";
            LDAP_ATTRIBUTE_USER_EMAIL = "mail";
            LDAP_ATTRIBUTE_USER_FIRST_NAME = "givenName";
            LDAP_ATTRIBUTE_USER_LAST_NAME = "sn";
            LDAP_ATTRIBUTE_USER_PROFILE_PICTURE = "jpegPhoto";
            LDAP_ATTRIBUTE_USER_UNIQUE_IDENTIFIER = "entryUUID";
            LDAP_ATTRIBUTE_USER_USERNAME = "uid";
            LDAP_BASE = "dc=kuipr,dc=de";
            LDAP_BIND_DN = "uid=admin,ou=people,dc=kuipr,dc=de";
            LDAP_ENABLED = "true";
            LDAP_URL = "ldap://lldap:3890";
          };
          log-driver = "journald";
          extraOptions = [
            # Podman does not inherit image HEALTHCHECKs.
            "--health-cmd=sh -c '/app/pocket-id healthcheck || exit 1'"
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=1m"
            "--health-timeout=30s"
            "--network-alias=pocketid"
            # --dns bypasses aardvark-dns so the resolver logs the container's own IP.
            "--network=pocketid_default:ip=10.89.4.24"
            "--network=proxy:ip=${proxyIp}"
            "--dns=192.168.0.85"
          ];
        };
      };

      systemd.services = {
        "podman-pocketid" = {
          serviceConfig = {
            Restart = lib.mkOverride 90 "always";
          };
          after = [
            "podman-network-pocketid_default.service"
            "podman-lldap.service"
          ];
          requires = [
            "podman-network-pocketid_default.service"
          ];
          wants = ["podman-lldap.service"];
          partOf = [
            "podman-compose-pocketid-root.target"
          ];
          wantedBy = [
            "podman-compose-pocketid-root.target"
          ];
        };

        "podman-pocketid-data" = {
          serviceConfig.Type = "oneshot";
          script = "${pkgs.podman}/bin/podman volume create pocketid_data || true";
          wantedBy = ["multi-user.target"];
        };

        "pocketid-bootstrap" = {
          description = "Print a one-time login link for the LDAP admin";
          wantedBy = ["multi-user.target"];
          after = ["network-online.target" "podman-pocketid.service"];
          wants = ["network-online.target"];
          requires = ["podman-pocketid.service"];
          path = [pkgs.podman];

          environment = {
            BOOTSTRAP_MARKER = "/var/lib/pocketid-bootstrap/login-link-issued";
            POCKETID_ADMIN_USERNAME = "admin";
          };

          serviceConfig = {
            Type = "oneshot";
            # Remains active so a changed ExecStart re-runs the check on switch-to-configuration.
            RemainAfterExit = true;
            StateDirectory = "pocketid-bootstrap";
            ExecStart = runBootstrap;
          };
        };

        "podman-network-pocketid_default" = {
          path = [pkgs.podman];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStop = "podman network rm -f pocketid_default";
          };
          script = ''
            podman network inspect pocketid_default || podman network create pocketid_default
          '';
          partOf = ["podman-compose-pocketid-root.target"];
          wantedBy = ["podman-compose-pocketid-root.target"];
        };
      };

      systemd.targets."podman-compose-pocketid-root" = {
        unitConfig = {
          Description = "Root target generated for Authelia.";
        };
        wantedBy = ["multi-user.target"];
      };
    };
  };
}
