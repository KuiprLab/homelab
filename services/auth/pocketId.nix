_: {
  flake = {
    pangolinVirtualHosts."pocketid" = {
      site = "sorbet";
      name = "PocketID";
      subdomain = "id.ext.kuipr.de";
      port = 9091;
      private = false;
    };

    nixosModules.pocketid = {
      pkgs,
      lib,
      config,
      ...
    }: {
      sops.secrets = {
        "pocketid/pocketid.env" = {
          sopsFile = ../../secrets/sorbet/pocketid/pocketid.env;
          format = "dotenv";
          owner = "daniel";
          key = "";
          restartUnits = ["podman-pocketid.service"];
        };

      };

      virtualisation.oci-containers.containers = {
        "pocketid" = {
          image = "docker.io/pocketid/pocket-id:v2";
          volumes = [
            "pocketid_data:/app/data:rw"
          ];
          ports = [
            "127.0.0.1:1411:1411/tcp"
          ];
          environmentFiles = [
            "${config.sops.secrets."pocketid/pocketid.env".path}"
          ];
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
            "--network=pocketid_default:ip=10.89.3.24"
            "--network=proxy"
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
            "podman-create-network-proxy.service"
          ];
          requires = [
            "podman-network-pocketid_default.service"
            "podman-create-network-proxy.service"
          ];
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
