_: {
  # Define the systems for per-system outputs
  systems = [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
  ];

  # Make nixpkgs available per-system
  perSystem = {pkgs, ...}: {
    # `formatter` and `checks.treefmt` come from modules/flake/treefmt.nix.
    # Everything below is linting, which inspects but never rewrites.
    checks = {
      deadcode = pkgs.runCommand "check-deadcode" {} ''
        ${pkgs.deadnix}/bin/deadnix --fail ${../../.} || exit 1
        touch $out
      '';

      linting = pkgs.runCommand "check-linting" {} ''
        ${pkgs.statix}/bin/statix check ${../../.} || exit 1
        touch $out
      '';
    };
  };
}
