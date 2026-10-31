{inputs, ...}: let
  rexModule = {config, ...}: let
    isEclair = config.networking.hostName == "eclair";
  in {
    imports = [inputs.rex.nixosModules.default];

    services.rex =
      if isEclair
      then {
        enable = true;
        user = "root";
        group = "root";
      }
      else {
        enable = true;
        user = "daniel";
        group = "rex";
        extraListen = ["127.0.0.1:7297"];
        allowAnonymous = true;
      };
  };
in {
  flake = {
    pangolinVirtualHosts."rex" = {
      site = "sorbet";
      name = "Rex";
      subdomain = "sorbet.int.kuipr.de";
      port = 7297;
      # Rex answers / with 404 and has no health endpoint.
      healthcheck.enable = false;
    };

    nixosModules.rex = rexModule;
    eclairNixosModules.rex = rexModule;
  };
}
