{
  self,
  inputs,
  lib,
  ...
}: let
  collectModules = attrs: lib.attrValues (lib.filterAttrs (_n: v: v != {}) attrs);

  sorbetTailscaleIp = "100.120.32.9";
in {
  options.flake.eclairNixosModules = lib.mkOption {
    type = lib.types.attrsOf lib.types.raw;
    default = {};
  };

  config.flake.nixosConfigurations.eclair = inputs.nixpkgs.lib.nixosSystem {
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
          _module.args = {
            inherit sorbetTailscaleIp;
          };

          # The module path moved in nixpkgs; the entry that does not exist matches nothing.
          disabledModules = [
            "services/security/crowdsec.nix"
            "services/security/crowdsec"
            "services/security/crowdsec-firewall-bouncer.nix"
          ];

          # The pinned crowdsec module has no doc.md, so nixos-manual-html fails the redirect check.
          documentation.nixos.checkRedirects = false;
        }
        "${inputs.nixpkgs-crowdsec}/nixos/modules/services/security/crowdsec.nix"
        "${inputs.nixpkgs-crowdsec}/nixos/modules/services/security/crowdsec-firewall-bouncer.nix"
        {system.configurationRevision = self.rev or self.dirtyRev or null;}
      ]
      ++ collectModules self.eclairNixosModules;
  };
}
