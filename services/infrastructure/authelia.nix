_: {
  flake = {
    pangolinVirtualHosts."auth" = {
      site = "sorbet";
      name = "Authelia";
      subdomain = "auth.ext.kuipr.de";
      port = 9091;
      private = false;
    };

    nixosModules.authelia = {
      pkgs,
      lib,
      config,
      ...
    }: {
      sops.secrets = {
        "authelia/authelia.env" = {
          sopsFile = ../../secrets/sorbet/authelia/authelia.env;
          format = "dotenv";
          owner = "daniel";
          key = "";
          restartUnits = ["podman-authelia.service"];
        };

        "authelia/configuration.yml" = {
          sopsFile = ../../secrets/sorbet/authelia/configuration.yml;
          owner = "daniel";
          format = "yaml";
          key = "";
          restartUnits = ["podman-authelia.service"];
        };

        "authelia/authelia-users.yaml" = {
          sopsFile = ../../secrets/sorbet/authelia/users.yaml;
          owner = "daniel";
          key = "";
          restartUnits = ["podman-authelia.service"];
        };
      };

      virtualisation.oci-containers.containers = {
        "authelia" = {
          image = "docker.io/authelia/authelia:4.39.28@sha256:bd97cff4fcbf715b5ff1f9ae286afbe6033afce385302520b0368122d43a6f54";
          volumes = [
            "${config.sops.secrets."authelia/configuration.yml".path}:/config/configuration.yml:ro"
            "authelia_data:/data:rw"
            # :ro: rotate hashes through the sops secret, never from inside the container.
            "${config.sops.secrets."authelia/authelia-users.yaml".path}:/config/users_database.yaml:ro"
          ];
          ports = [
            "127.0.0.1:9091:9091/tcp"
          ];
          environmentFiles = [
            "${config.sops.secrets."authelia/authelia.env".path}"
          ];
          log-driver = "journald";
          extraOptions = [
            # Podman does not inherit image HEALTHCHECKs.
            "--health-cmd=sh -c 'n=0; until /app/healthcheck.sh; do n=$((n+1)); [ $n -ge 8 ] && exit 1; sleep 2; done'"
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=1m"
            "--health-timeout=30s"
            "--network-alias=authelia"
            # --dns bypasses aardvark-dns so the resolver logs the container's own IP.
            "--network=authelia_default:ip=10.89.2.20"
            "--network=proxy"
            "--dns=192.168.0.85"
          ];
        };
      };

      systemd.services = {
        "podman-authelia" = {
          serviceConfig = {
            Restart = lib.mkOverride 90 "always";
          };
          after = [
            "podman-network-authelia_default.service"
            "podman-create-network-proxy.service"
          ];
          requires = [
            "podman-network-authelia_default.service"
            "podman-create-network-proxy.service"
          ];
          partOf = [
            "podman-compose-authelia-root.target"
          ];
          wantedBy = [
            "podman-compose-authelia-root.target"
          ];
        };

        "podman-authelia-data" = {
          serviceConfig.Type = "oneshot";
          script = "${pkgs.podman}/bin/podman volume create authelia_data || true";
          wantedBy = ["multi-user.target"];
        };

        "podman-network-authelia_default" = {
          path = [pkgs.podman];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStop = "podman network rm -f authelia_default";
          };
          script = ''
            podman network inspect authelia_default || podman network create authelia_default
          '';
          partOf = ["podman-compose-authelia-root.target"];
          wantedBy = ["podman-compose-authelia-root.target"];
        };
      };

      systemd.targets."podman-compose-authelia-root" = {
        unitConfig = {
          Description = "Root target generated for Authelia.";
        };
        wantedBy = ["multi-user.target"];
      };
    };
  };
}
