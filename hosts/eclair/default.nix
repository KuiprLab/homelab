# eclair — tiny public VPS
# Runs pangolin + haproxy + crowdsec; pangolin covers cross-host overlay.
# Routes *.ext.kuipr.de and *.int.kuipr.de wildcard resources.
{
  self,
  inputs,
  lib,
  ...
}: let
  collectModules = attrs: lib.attrValues (lib.filterAttrs (_n: v: v != {}) attrs);

  # Legacy arg, unused since the tailscale removal; can be dropped with callers.
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
          # Pass flake-level values into nixos modules via _module.args
          _module.args = {
            inherit sorbetTailscaleIp;
          };

          # Replace upstream crowdsec modules with the PR rewrite (see flake.nix).
          # nixpkgs moved `services/security/crowdsec.nix` to a
          # `services/security/crowdsec/` directory, which changes the module
          # key, so list both the old file and the new directory; the entry
          # that does not exist in the pinned nixpkgs matches nothing.
          disabledModules = [
            "services/security/crowdsec.nix"
            "services/security/crowdsec"
            "services/security/crowdsec-firewall-bouncer.nix"
          ];
        }
        # Import crowdsec modules from the PR branch
        "${inputs.nixpkgs-crowdsec}/nixos/modules/services/security/crowdsec.nix"
        "${inputs.nixpkgs-crowdsec}/nixos/modules/services/security/crowdsec-firewall-bouncer.nix"
        # Record the build revision (see hosts/sorbet/default.nix).
        {system.configurationRevision = self.rev or self.dirtyRev or null;}
      ]
      ++ collectModules self.eclairNixosModules;
  };
}
