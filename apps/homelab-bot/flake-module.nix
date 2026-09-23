# The only file in this directory import-tree picks up. Its siblings are
# prefixed with _ so they are skipped, and are pulled in from here instead --
# one place that says how this app is built and how it is run.
_: {
  perSystem = {pkgs, ...}: {
    packages.homelab-bot = pkgs.callPackage ./_package.nix {};
  };

  flake.nixosModules.homelab-bot = import ./_module.nix;
}
