_: {
  flake = {
    caddyVirtualHosts."auth.ext.kuipr.de" = {
      extraConfig = ''
        reverse_proxy localhost:9091
      '';
      name = "Authelia";
    };
    nixosModules.authelia = {
      pkgs,
      lib,
      config,
      ...
    }: {
      sops.secrets = {
        "authelia/authelia.env" = {
          sopsFile = ../secrets/sorbet/authelia/authelia.env;
          format = "dotenv";
          owner = "daniel";
          key = "";
          restartUnits = ["podman-authelia.service"];
        };

        "authelia/configuration.yml" = {
          sopsFile = ../secrets/sorbet/authelia/configuration.yml;
          owner = "daniel";
          format = "yaml";
          key = "";
          restartUnits = ["podman-authelia.service"];
        };

        "authelia/authelia-users.yaml" = {
          sopsFile = ../secrets/sorbet/authelia/users.yaml;
          owner = "daniel";
          key = "";
          restartUnits = ["podman-authelia.service"];
        };
      };

      # Containers
      virtualisation.oci-containers.containers = {
        "authelia" = {
          image = "docker.io/authelia/authelia:4.38.8@sha256:19375b10024caeef4e0b119a6247beae84cbaa02c846cfd750e92dea910d4b6a";
          volumes = [
            "${config.sops.secrets."authelia/configuration.yml".path}:/config/configuration.yml:ro"
            "authelia_data:/data:rw"
            # :ro -- a compromised container must not be able to rewrite the
            # password hashes; rotate by regenerating the sops secret instead.
            "${config.sops.secrets."authelia/authelia-users.yaml".path}:/config/users_database.yaml:ro"
          ];
          ports = [
            # loopback only: caddy (host) proxies auth.ext.kuipr.de -> here;
            # never expose the auth service to LAN/tailnet directly
            "127.0.0.1:9091:9091/tcp"
          ];
          environmentFiles = [
            "${config.sops.secrets."authelia/authelia.env".path}"
          ];
          log-driver = "journald";
          # Podman does not inherit image HEALTHCHECKs — mirror the upstream
          # one explicitly (healthcheck.sh probes /api/health on 9091).
          # Unhealthy → podman kills the container; the unit's Restart=always
          # (set below) recreates it.
          extraOptions = [
            # Retry inside the command: podman's first check fires immediately at
            # start, and a failed transient-unit check aborts NixOS activations.
            "--health-cmd=sh -c 'n=0; until /app/healthcheck.sh; do n=$((n+1)); [ $n -ge 8 ] && exit 1; sleep 2; done'"
            "--health-interval=30s"
            "--health-on-failure=kill"
            "--health-retries=3"
            "--health-start-period=1m"
            "--health-timeout=30s"
            "--network-alias=authelia"
            # Pinned IP + --dns=192.168.0.85: per-container DNS attribution in
            # Pi-hole — host dnsmasq tags ECS with the container's IP, which
            # FTL names via its dns_hosts table (bypasses aardvark-dns, so no
            # podman inter-container name resolution).
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

        # Networks
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

      # Root service
      # When started, this will automatically create all resources and start
      # the containers. When stopped, this will teardown all resources.
      systemd.targets."podman-compose-authelia-root" = {
        unitConfig = {
          Description = "Root target generated for Authelia.";
        };
        wantedBy = ["multi-user.target"];
      };
    };
  };
}
