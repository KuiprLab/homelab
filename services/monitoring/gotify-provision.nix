_: let
  mkProvision = import ../../apps/gotify-provision/_module.nix;
in {
  flake.nixosModules.gotifyProvision = mkProvision {
    apps = {
      comin-sorbet = {
        icon = "nixos";
      };
      beets = {
        icon = "beets";
      };
      healthchecks = {
        icon = "healthchecks";
      };
      beszel = {
        icon = "beszel";
      };
      crowdsec = {
        icon = "crowdsec";
      };
      pangolin = {
        icon = "pangolin";
      };
    };
    baseUrl = "http://gotify:80";
    gotifyDeps = ["podman-gotify.service"];
  };

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
