{
  self,
  inputs,
  lib,
  ...
}: let
  nixpkgsConfig = {
    allowUnfree = true;
    allowBroken = false;
    allowUnsupportedSystem = false;
  };

  overlays = [
  ];

  # sorbetConfiguration/HardwareConfiguration are listed explicitly; merging them twice duplicates lists.
  collectModules = attrs: lib.attrValues (lib.filterAttrs (n: v: v != {} && n != "sorbetConfiguration" && n != "sorbetHardwareConfiguration") attrs);
in {
  flake = {
    nixosModules = {};
    homeManagerModules = {};

    nixosConfigurations.sorbet = inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules =
        [
          self.nixosModules.sorbetConfiguration
          self.nixosModules.sorbetHardwareConfiguration
          inputs.home-manager.nixosModules.home-manager
          inputs.determinate.nixosModules.default

          inputs.sops-nix.nixosModules.sops
          {
            nixpkgs.config = nixpkgsConfig;
            nixpkgs.overlays = overlays;
          }

          {system.configurationRevision = self.rev or self.dirtyRev or null;}

          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              backupFileExtension = "backup";
              sharedModules =
                [
                  inputs.sops-nix.homeManagerModules.sops
                ]
                ++ collectModules self.homeManagerModules;
            };
          }
        ]
        ++ collectModules self.nixosModules;
    };
  };
}
