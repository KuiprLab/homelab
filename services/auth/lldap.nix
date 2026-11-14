{config, ...}: let
  constants = config.flake.constants;
  proxyIp = "10.89.0.50";
  vhost = config.flake.pangolinVirtualHosts."lldap";
  traefikLabels = config.flake.sorbetTraefikLabels "lldap" vhost;
in {
  flake = {
    podmanProxyHosts.lldap.ip = proxyIp;

    pangolinVirtualHosts."lldap" = {
      site = "sorbet";
      name = "LLDAP";
      subdomain = "lldap.int.kuipr.de";
      hostname = "lldap";
      port = 17170;
      private = true;
    };

    nixosModules.lldap = {
      pkgs,
      lib,
      config,
      ...
    }: let
      image = "ghcr.io/lldap/lldap:latest";

      # bootstrap.sh reads one JSON object per file, so users.json and groups.json are split per entry.
      splitConfigs = pkgs.writeShellScript "lldap-split-configs" ''
        set -euo pipefail
        umask 077

        outputDir="$1"
        mkdir -p "$outputDir"
        rm -rf "$outputDir/user-configs" "$outputDir/group-configs"
        mkdir -p "$outputDir/user-configs" "$outputDir/group-configs"

        ${pkgs.jq}/bin/jq --compact-output 'to_entries[] | {id: .key} + .value' \
          ${config.sops.secrets."lldap/users".path} |
          while IFS= read -r userConfig; do
            printf '%s' "$userConfig" >"$outputDir/user-configs/$(printf '%s' "$userConfig" | ${pkgs.jq}/bin/jq --raw-output .id).json"
          done

        ${pkgs.jq}/bin/jq --compact-output 'to_entries[] | {name: .key} + .value' \
          ${config.sops.secrets."lldap/groups".path} |
          while IFS= read -r groupConfig; do
            printf '%s' "$groupConfig" >"$outputDir/group-configs/$(printf '%s' "$groupConfig" | ${pkgs.jq}/bin/jq --raw-output .name).json"
          done
      '';

      # For user and group configuration see: https://github.com/lldap/lldap/blob/main/example_configs/bootstrap/bootstrap.md
      runBootstrap = pkgs.writeShellScript "lldap-bootstrap" ''
        set -euo pipefail

        LLDAP_ADMIN_PASSWORD="$(sed -n 's/^LLDAP_LDAP_USER_PASS=//p' ${config.sops.secrets."lldap/lldap.env".path})"
        : ''${LLDAP_ADMIN_PASSWORD:?LLDAP_LDAP_USER_PASS missing from lldap.env}
        export LLDAP_ADMIN_PASSWORD

        # --env without a value forwards the variable, so the password stays out of the process argv.
        exec ${pkgs.podman}/bin/podman run --rm \
          --network=proxy \
          --entrypoint=/app/bootstrap.sh \
          --env=LLDAP_URL \
          --env=LLDAP_ADMIN_USERNAME \
          --env=LLDAP_ADMIN_PASSWORD \
          --env=DO_CLEANUP \
          --volume=/run/lldap-bootstrap:/bootstrap:ro \
          ${image}
      '';

      # The image's wait loop never gives up and never says why; this one does both differ for.
      waitForLldap = pkgs.writeShellScript "lldap-wait" ''
        for _ in $(seq 1 40); do
          if ${pkgs.curl}/bin/curl -fsS -m 3 "$LLDAP_URL/health" >/dev/null; then
            exit 0
          fi
          sleep 5
        done
        echo "lldap did not answer $LLDAP_URL within 200s; check podman logs lldap" >&2
        exit 1
      '';
    in {
      sops.secrets = {
        "lldap/lldap.env" = {
          sopsFile = ../../secrets/sorbet/lldap/lldap.env;
          format = "dotenv";
          owner = "daniel";
          key = "";
          restartUnits = ["podman-lldap.service" "lldap-bootstrap.service"];
        };

        "lldap/users" = {
          sopsFile = ../../secrets/sorbet/lldap/users.json;
          format = "json";
          key = "";
          restartUnits = ["lldap-bootstrap.service"];
        };

        "lldap/groups" = {
          sopsFile = ../../secrets/sorbet/lldap/groups.json;
          format = "json";
          key = "";
          restartUnits = ["lldap-bootstrap.service"];
        };
      };

      virtualisation.oci-containers.containers = {
        "lldap" = {
          labels = traefikLabels;
          inherit image;
          volumes = [
            "lldap_data:/data:rw"
          ];
          environmentFiles = [
            "${config.sops.secrets."lldap/lldap.env".path}"
          ];
          log-driver = "journald";
          extraOptions = [
            "--network-alias=lldap"
            # --dns bypasses aardvark-dns so the resolver logs the container's own IP.
            # One network only: lldap_default was a systemd unit whose ExecStop ran
            # `podman network rm -f`, so a switch could delete the network under the
            # running container, stranding its DNS name and wedging the bootstrap.
            "--network=proxy:ip=${proxyIp}"
            "--dns=${constants.lanIp}"
          ];
        };
      };

      systemd.services = {
        "lldap-bootstrap" = {
          description = "Reconcile LLDAP users, groups and memberships";
          wantedBy = ["multi-user.target"];
          after = ["network-online.target" "podman-lldap.service"];
          wants = ["network-online.target"];
          requires = ["podman-lldap.service"];

          environment = {
            DO_CLEANUP = "true";
            LLDAP_ADMIN_USERNAME = "admin";
            LLDAP_URL = "http://lldap:17170";
          };

          serviceConfig = {
            Type = "oneshot";
            # Remains active so a changed ExecStart re-runs the sync on switch-to-configuration.
            RemainAfterExit = true;
            ExecStartPre = [
              "${splitConfigs} /run/lldap-bootstrap"
              waitForLldap
            ];
            ExecStart = runBootstrap;
            # A sync that cannot reach lldap must fail, not hold multi-user.target and
            # with it the entire switch-to-configuration.
            TimeoutStartSec = 300;
          };
        };

        "podman-lldap" = {
          serviceConfig = {
            Restart = lib.mkOverride 90 "always";
          };
          partOf = [
            "podman-compose-lldap-root.target"
          ];
          wantedBy = [
            "podman-compose-lldap-root.target"
          ];
        };

        "podman-lldap-data" = {
          serviceConfig.Type = "oneshot";
          script = "${pkgs.podman}/bin/podman volume create lldap_data || true";
          wantedBy = ["multi-user.target"];
        };
      };

      systemd.targets."podman-compose-lldap-root" = {
        wantedBy = ["multi-user.target"];
      };
    };
  };
}
