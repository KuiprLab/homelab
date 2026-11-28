{
  self,
  inputs,
  lib,
  config,
  ...
}: let
  constants = config.flake.constants;

  # k3s brings containerd and sorbet is not a pangolin site: neither module has a job here.
  nodeHostModules = removeAttrs self.hostModules ["newt" "podman"];

  mkSorbet = system: modules:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules =
        [
          self.nixosModules.sorbetConfiguration
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
        ]
        ++ lib.attrValues (lib.filterAttrs (_: m: m != {}) nodeHostModules)
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
