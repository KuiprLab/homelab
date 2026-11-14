{config, ...}: let
  healthFlags = config.flake.healthFlags;
  proxyIp = "10.89.0.70";
  vhost = config.flake.pangolinVirtualHosts."tiny-cdn";
  labels =
    config.flake.pangolinRuleLabels "tiny-cdn"
    // config.flake.pangolinHealthcheckLabels "tiny-cdn" vhost
    // config.flake.pangolinPublicLabels "tiny-cdn" vhost;
in {
  flake = {
    podmanProxyHosts.tiny-cdn.ip = proxyIp;

    pangolinVirtualHosts."tiny-cdn" = {
      site = "sorbet";
      name = "tiny-cdn";
      subdomain = "cdn.ext.kuipr.de";
      private = false;
      hostname = "tiny-cdn";
      port = 3030;
      healthcheck.path = "/health";
    };

    nixosModules.tiny-cdn = import ./_module.nix {
      inherit healthFlags labels proxyIp;
    };
  };

  perSystem = {pkgs, ...}: {
    packages.tiny-cdn = pkgs.callPackage ./_package.nix {};

    devShells.tiny-cdn = pkgs.mkShell {
      packages = with pkgs; [
        cargo
        clippy
        rust-analyzer
        rustc
        rustfmt
      ];

      shellHook = ''
        echo "tiny-cdn -- $(rustc --version)"
        echo
        echo "  cargo test          unit tests"
        echo "  cargo clippy        lints"
        echo "  nix build .#tiny-cdn"
        echo
      '';
    };
  };
}
