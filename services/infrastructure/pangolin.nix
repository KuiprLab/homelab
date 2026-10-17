_: {
  flake = {
    sops.secrets = {
      "pangolin" = {
        sopsFile = ../../secrets/eclair/pangolin.env;
        format = "env";
        key = "";
        owner = "root";
      };

      "newt/sorbet" = {
        sopsFile = ../../secrets/sorbet/newt.env;
        format = "env";
        key = "";
        owner = "root";
      };

      "newt/eclair" = {
        sopsFile = ../../secrets/eclair/newt-eclair.env;
        format = "env";
        key = "";
        owner = "root";
      };
    };

    eclairNixosModules.pangolin-server = {config, ...}: {
      services.pangolin = {
        enable = true;
        dashboardDomain = "pangolin.kuipr.de";
        baseDomain = "kuipr.de";
        dnsProvider = "bunny";
        letsEncryptEmail = "62436912+frostplexx@users.noreply.github.com";
        environmentFile = config.sops.secrets."pangolin".path;
        openFirewall = true;
      };
    };

    eclairNixosModules.newt = {config, ...}: {
      services.newt = {
        enable = true;
        environmentFile = config.sops.secrets."newt/eclair".path;
        settings = {
          endpoint = "${config.services.pangolin.dashboardDomain}";
          id = "eclair";
        };
      };
    };

    nixosModules.newt = {config, ...}: {
      services.newt = {
        enable = true;
        environmentFile = config.sops.secrets."newt/sorbet".path;
        settings = {
          endpoint = "${config.services.pangolin.dashboardDomain}";
          id = "sorbet";
        };
      };
    };
  };
}
