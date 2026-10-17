_: {
  flake = {
    eclairNixosModules.pangolin-server = {config, ...}: {
      sops.secrets."pangolin" = {
        sopsFile = ../../secrets/eclair/pangolin.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      services.pangolin = {
        enable = true;
        dashboardDomain = "pangolin.ext.kuipr.de";
        baseDomain = "kuipr.de";
        dnsProvider = "bunny";
        letsEncryptEmail = "62436912+frostplexx@users.noreply.github.com";
        environmentFile = config.sops.secrets."pangolin".path;
        openFirewall = true;
      };
    };

    eclairNixosModules.newt = {config, ...}: {
      sops.secrets."newt-eclair" = {
        sopsFile = ../../secrets/eclair/newt.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      services.newt = {
        enable = true;
        environmentFile = config.sops.secrets."newt-eclair".path;
        settings = {
          endpoint = "https://${config.services.pangolin.dashboardDomain}";
          id = "eclair";
        };
      };
    };

    nixosModules.newt = {config, ...}: {
      sops.secrets."newt-sorbet" = {
        sopsFile = ../../secrets/sorbet/newt.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      services.newt = {
        enable = true;
        environmentFile = config.sops.secrets."newt-sorbet".path;
        settings = {
          # The pangolin server runs on eclair; this module is evaluated on
          # sorbet where services.pangolin.dashboardDomain is unset ("").
          endpoint = "https://pangolin.kuipr.de";
          id = "sorbet";
        };
      };
    };
  };
}
