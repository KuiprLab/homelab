_: {
  # x86_64-linux builds the hosts; aarch64-darwin is the workstation dev shell.
  systems = [
    "x86_64-linux"
    "aarch64-darwin"
  ];

  perSystem = {pkgs, ...}: {
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
