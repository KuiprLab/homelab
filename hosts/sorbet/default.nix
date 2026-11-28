{
  self,
  inputs,
  lib,
  config,
  ...
}: let
  constants = config.flake.constants;

  collectHostModules = attrs: lib.attrValues (lib.filterAttrs (_: v: v != {}) attrs);

  mkSorbet = system: modules:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules =
        [
          self.nixosModules.sorbetConfiguration
          inputs.home-manager.nixosModules.home-manager
          inputs.determinate.nixosModules.default
          inputs.sops-nix.nixosModules.sops
          {
            nixpkgs.config = {
              allowUnfree = true;
              allowBroken = false;
              allowUnsupportedSystem = false;
            };
          }
          {system.configurationRevision = self.rev or self.dirtyRev or null;}
          {
            home-manager = {
              useGlobalPkgs = true;
              useUserPackages = true;
              backupFileExtension = "backup";
              sharedModules = [
                inputs.sops-nix.homeManagerModules.sops
              ];
            };
          }
        ]
        ++ collectHostModules self.hostModules
        ++ modules;
    };
in {
  flake.nixosConfigurations = {
    sorbet = mkSorbet "x86_64-linux" [
      self.nixosModules.sorbetHardwareConfiguration
      ./_k3s.nix
      (import ./_network.nix {inherit constants;})
    ];

    # aarch64-linux: the OrbStack VM on the workstation.
    sorbet-dev = mkSorbet "aarch64-linux" [
      ./_k3s.nix
      ./_dev.nix
    ];
  };
}
