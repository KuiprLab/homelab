_: {
  flake = {
    caddyVirtualHosts = {
      "explo.int.kuipr.de" = {
        extraConfig = ''
          reverse_proxy localhost:7288
        '';
        name = "Explo";
      };
    };

    nixosModules.explo = {config, ...}: {
      sops.secrets = {
        "explo" = {
          sopsFile = ../../../secrets/sorbet/explo.env;
          format = "dotenv";
          key = "";
        };
      };

      virtualisation.oci-containers = {
        containers = {
          explo = {
            volumes = [
              "${config.sops.secrets."explo".path}:/opt/explo/.env"
              "/media/data/music/explo:/data/"
              "/home/daniel/slskd-downloads:/slskd/"
            ];
            environment.TZ = "Europe/Berlin";
            image = "ghcr.io/lumepart/explo:dev";
            ports = [
              "7288:7288"
            ];
            labels = {
              "io.containers.autoupdate" = "registry";
            };
          };
        };
      };
    };
  };
}
