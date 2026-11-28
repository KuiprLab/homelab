_: let
  mkProvision = import ../../apps/gotify-provision/_module.nix;
in {
  flake.eclairNixosModules.gotifyProvision = mkProvision {
    apps = {
      comin-eclair = {
        icon = "nixos";
      };
    };
    baseUrl = "https://gotify.ext.kuipr.de";
    defineAdminSecret = true;
  };
}
