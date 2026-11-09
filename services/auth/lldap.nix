_: {
  flake = {
    pangolinVirtualHosts."lldap" = {
      site = "sorbet";
      name = "LLDAP";
      subdomain = "lldap.int.kuipr.de";
      port = 17107;
      private = true;
    };
    
    nixosModules.lldap = {
      pkgs,
      lib,
      config,
      ...
    }: {
      sops.secrets = {
        "lldap.env" = {
          sopsFile = ../../secrets/sorbet/lldap.env;
          format = "dotenv";
          owner = "daniel";
          key = "";
          restartUnits = ["podman-lldap.service"];
        };
      };

      virtualisation.oci-containers.containers = {
        "lldap" = {
          image = "ghcr.io/lldap/lldap:latest";
          volumes = [
            "lldap_data:/data:rw"
          ];
          ports = [
            "127.0.0.1:17170:17170/tcp"
          ];
          environmentFiles = [
            "${config.sops.secrets."lldap.env".path}"
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
            "--network=lldap_default:ip=10.89.2.20"
            "--network=proxy"
            "--dns=192.168.0.85"
          ];
        };
      };

      systemd.services = {
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
