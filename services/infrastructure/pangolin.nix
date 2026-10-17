_: {
  flake = {
    sops.secrets."pangolin" = {
      sopsFile = ../../secrets/eclair/pangolin.env;
      format = "env";
      key = "";
      owner = "root";
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
        settings = {
          endpoint = "${config.services.pangolin.dashboardDomain}";
          id = "eclair";
        };
      };
    };

    nixosModules.newt = {config, ...}: {
      services.newt = {
        enable = true;
        settings = {
          endpoint = "${config.services.pangolin.dashboardDomain}";
          id = "sorbet";
        };
      };
    };
  };
}
