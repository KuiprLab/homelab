# eclair — tiny public VPS
# Runs haproxy (TCP SNI proxy) + CrowdSec, connected via tailnet.
# Routes *.ext.kuipr.de → sorbet's tailscale IP (caddy terminates TLS).
{
  self,
  inputs,
  lib,
  config,
  ...
}: let
  collectModules = attrs: lib.attrValues (lib.filterAttrs (_n: v: v != {}) attrs);

  # Set this to the output of `tailscale ip -4` on sorbet after eclair joins the tailnet.
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
          _module.args.sorbetTailscaleIp = sorbetTailscaleIp;
          _module.args.caddyVirtualHosts = config.flake.caddyVirtualHosts;
          _module.args.eclairCaddyVirtualHosts = config.flake.eclairCaddyVirtualHosts;

          # Replace upstream crowdsec modules with PR #446307
          disabledModules = [
            "services/security/crowdsec.nix"
            "services/security/crowdsec-firewall-bouncer.nix"
          ];
        }
        # Import crowdsec modules from the PR branch
        "${inputs.nixpkgs-crowdsec}/nixos/modules/services/security/crowdsec.nix"
        "${inputs.nixpkgs-crowdsec}/nixos/modules/services/security/crowdsec-firewall-bouncer.nix"
      ]
      ++ collectModules self.eclairNixosModules;
  };
}
