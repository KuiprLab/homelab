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
          image = "docker.io/authelia/authelia:4.38.8";
          volumes = [
            "${config.sops.secrets."authelia/configuration.yml".path}:/config/configuration.yml:ro"
            "authelia_data:/data:rw"
            "${config.sops.secrets."authelia/authelia-users.yaml".path}:/config/users_database.yaml:rw"
          ];
          ports = [
            "9091:9091/tcp"
          ];
          environmentFiles = [
            "${config.sops.secrets."authelia/authelia.env".path}"
          ];
          labels = {
            "io.containers.autoupdate" = "registry";
          };
          log-driver = "journald";
          extraOptions = [
            "--network-alias=authelia"
            "--network=authelia_default"
            "--network=proxy"
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
