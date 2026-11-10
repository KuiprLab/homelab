{inputs, ...}: let
  mkRexModule = user: _: {
    imports = [inputs.rex.nixosModules.default];

    services.rex = {
      enable = true;
      inherit user;
      group = "rex";
      allowAnonymous = false;
    };
  };
in {
  flake = {
    nixosModules.rex = mkRexModule "daniel";
    eclairNixosModules.rex = mkRexModule "rex";
  };
}
