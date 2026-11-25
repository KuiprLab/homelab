{
  self,
  inputs,
  lib,
  ...
}: {
  options.flake.crossaintNixosModules = lib.mkOption {
    type = lib.types.attrsOf lib.types.raw;
    default = {};
  };

  config.flake.nixosConfigurations.crossaint = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules =
      [
        inputs.sops-nix.nixosModules.sops
        inputs.determinate.nixosModules.default
        {
          nixpkgs.config = {
            allowUnfree = true;
            allowBroken = false;
          };
        }
        {system.configurationRevision = self.rev or self.dirtyRev or null;}
      ]
      ++ lib.attrValues self.hostModules
      ++ lib.attrValues self.crossaintNixosModules;
  };
}
