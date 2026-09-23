{
  self,
  inputs,
  lib,
  ...
}: let
  # Shared nixpkgs config
  nixpkgsConfig = {
    allowUnfree = true;
    allowBroken = false;
    allowUnsupportedSystem = false;
  };

  # Overlays
  overlays = [
  ];

  # Helper to collect all modules from an attrset
  # sorbetConfiguration and sorbetHardwareConfiguration are declared
  # explicitly below; skip them in the bulk collection so they do not
  # merge twice (list options like podman subnets would duplicate).
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
          # Core modules
          inputs.home-manager.nixosModules.home-manager
          inputs.determinate.nixosModules.default

          inputs.sops-nix.nixosModules.sops
          # Nixpkgs configuration
          {
            nixpkgs.config = nixpkgsConfig;
            nixpkgs.overlays = overlays;
          }

          # Home Manager shared modules
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
