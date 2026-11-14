{config, ...}: let
  proxyIp = "10.89.0.70";
  vhost = config.flake.pangolinVirtualHosts."tiny-cdn";
  labels =
    config.flake.pangolinRuleLabels "tiny-cdn"
    // config.flake.pangolinHealthcheckLabels "tiny-cdn" vhost
    // {
      "pangolin.proxy-resources.tiny-cdn.name" = vhost.name;
      "pangolin.proxy-resources.tiny-cdn.full-domain" = vhost.subdomain;
      "pangolin.proxy-resources.tiny-cdn.mode" = "http";
      "pangolin.proxy-resources.tiny-cdn.labels[0]" = "edge:public";
      "pangolin.proxy-resources.tiny-cdn.labels[1]" = "site:${vhost.site}";
      "pangolin.proxy-resources.tiny-cdn.targets[0].hostname" = vhost.hostname;
      "pangolin.proxy-resources.tiny-cdn.targets[0].port" = toString vhost.port;
      "pangolin.proxy-resources.tiny-cdn.targets[0].method" = vhost.protocol;
    };
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
      inherit labels proxyIp;
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
        echo "  scripts/upload.sh   signed client, see README.md"
        echo
      '';
    };
  };
}
