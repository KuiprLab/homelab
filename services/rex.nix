{inputs, ...}: let
  rexModule = {config, ...}: let
    isEclair = config.networking.hostName == "eclair";
  in {
    imports = [inputs.rex.nixosModules.default];

    services = {
      rex =
        if isEclair
        then {
          enable = true;
          user = "root";
          group = "root";
          tailscaleServe.enable = true;
        }
        else {
          enable = true;
          user = "daniel";
          group = "rex";
          tailscaleServe.enable = true;
        };
      tailscale.enable = true;
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
