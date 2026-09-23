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
    # Default formatter
    formatter = pkgs.alejandra;

    # Checks for CI
    checks = {
      formatting = pkgs.runCommand "check-formatting" {} ''
        ${pkgs.alejandra}/bin/alejandra --check ${../../.} || exit 1
        touch $out
      '';

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
