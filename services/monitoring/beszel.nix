_: {
  flake.eclairNixosModules.beszelAgent = {config, ...}: {
    sops.secrets."beszel/agent" = {
      sopsFile = ../../secrets/eclair/beszel-agent;
      format = "binary";
      key = "";
      owner = "root";
    };

    services.beszel.agent = {
      enable = true;
      environment = {
        HUB_URL = "https://monitoring.ext.kuipr.de";
        DISABLE_SSH = "true";
      };
      environmentFile = config.sops.secrets."beszel/agent".path;
    };
  };
}
