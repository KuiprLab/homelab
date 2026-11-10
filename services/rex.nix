{inputs, ...}: let
  rexModule = _: {
    imports = [inputs.rex.nixosModules.default];

    services.rex = {
      enable = true;
      user = "daniel";
      group = "rex";
      allowAnonymous = false;
    };
  };
in {
  flake = {
    nixosModules.rex = rexModule;
  };
}
