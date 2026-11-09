_: {
  flake = {
    pangolinVirtualHosts."lldap" = {
      site = "sorbet";
      name = "LLDAP";
      subdomain = "lldap.int.kuipr.de";
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

      runBootstrap = pkgs.writeShellScript "lldap-bootstrap" ''
        set -euo pipefail

        LLDAP_ADMIN_PASSWORD="$(sed -n 's/^LLDAP_LDAP_USER_PASS=//p' ${config.sops.secrets."lldap/lldap.env".path})"
        : ''${LLDAP_ADMIN_PASSWORD:?LLDAP_LDAP_USER_PASS missing from lldap.env}
        export LLDAP_ADMIN_PASSWORD

        # --env without a value forwards the variable, so the password stays out of the process argv.
        exec ${pkgs.podman}/bin/podman run --rm \
          --network=lldap_default \
          --entrypoint=/app/bootstrap.sh \
          --env=LLDAP_URL \
          --env=LLDAP_ADMIN_USERNAME \
          --env=LLDAP_ADMIN_PASSWORD \
          --env=DO_CLEANUP \
          --volume=/run/lldap-bootstrap:/bootstrap:ro \
          ${image}
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
          image = image;
          volumes = [
            "lldap_data:/data:rw"
          ];
          ports = [
            "127.0.0.1:17170:17170/tcp"
          ];
          environmentFiles = [
            "${config.sops.secrets."lldap/lldap.env".path}"
          ];
          log-driver = "journald";
          extraOptions = [
            # Podman does not inherit image HEALTHCHECKs.
            # "--health-cmd=sh -c 'n=0; until /app/healthcheck.sh; do n=$((n+1)); [ $n -ge 8 ] && exit 1; sleep 2; done'"
            # "--health-interval=30s"
            # "--health-on-failure=kill"
            # "--health-retries=3"
            # "--health-start-period=1m"
            # "--health-timeout=30s"
            "--network-alias=lldap"
            # --dns bypasses aardvark-dns so the resolver logs the container's own IP.
            "--network=lldap_default:ip=10.89.3.21"
            "--network=proxy"
            "--dns=192.168.0.85"
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
            ExecStartPre = "${splitConfigs} /run/lldap-bootstrap";
            ExecStart = runBootstrap;
          };
        };

        "podman-lldap" = {
          serviceConfig = {
            Restart = lib.mkOverride 90 "always";
          };
          after = [
            "podman-network-lldap_default.service"
            "podman-create-network-proxy.service"
          ];
          requires = [
            "podman-network-lldap_default.service"
            "podman-create-network-proxy.service"
          ];
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

        "podman-network-lldap_default" = {
          path = [pkgs.podman];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStop = "podman network rm -f lldap_default";
          };
          script = ''
            podman network inspect lldap_default || podman network create lldap_default
          '';
          partOf = ["podman-compose-lldap-root.target"];
          wantedBy = ["podman-compose-lldap-root.target"];
        };
      };

      systemd.targets."podman-compose-lldap-root" = {
        unitConfig = {
          Description = "Root target generated for Authelia.";
        };
        wantedBy = ["multi-user.target"];
      };
    };
  };
}
