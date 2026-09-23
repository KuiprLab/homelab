{
  description = "Homelab Server";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    import-tree.url = "github:vic/import-tree";

    wrapper-modules.url = "github:BirdeeHub/nix-wrapper-modules";

    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # One `nix fmt` for every language in the tree, not just Nix.
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nixpkgs PR #446307 — crowdsec module refactor
    # Overrides the upstream crowdsec NixOS modules on eclair.
    nixpkgs-crowdsec.url = "github:TornaxO7/nixpkgs/crowdsec";
  };

  # Dendritic: every .nix file under these roots is a flake-parts module that
  # contributes its own outputs. Paths containing /_ are skipped -- that is how
  # a directory keeps helper files (_package.nix, _module.nix) next to its
  # module without them being evaluated as flake-parts modules.
  #
  # ./pkgs is deliberately absent: its files are a derivation and a NixOS
  # module, imported by hand from services/unifi.nix.
  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;}
    (inputs.import-tree [
      ./apps
      ./hosts
      ./modules
      ./services
    ]);
}
