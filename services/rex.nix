{inputs, ...}: let
  rexModule = _: {
    imports = [inputs.rex.nixosModules.default];

    services.rex = {
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
  };
}
