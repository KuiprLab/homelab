{
  inputs,
  lib,
  ...
}: {
  imports = [inputs.treefmt-nix.flakeModule];

  perSystem = _: {
    treefmt = {
      projectRootFile = "flake.nix";

      programs = {
        alejandra.enable = true;
        shfmt.enable = true;
        prettier.enable = true;
      };

      # The tree is 2-space; treefmt-nix stopped defaulting shfmt to it.
      programs.shfmt.indent_size = 2;

      # scripts/import-music has no .sh suffix; the default shfmt globs miss it.
      settings.formatter.shfmt.includes = ["scripts/import-music"];

      # prettier would reformat md/json/yaml too; scoped to TS until that churn is wanted.
      settings.formatter.prettier.includes = lib.mkForce [
        "*.ts"
        "*.mts"
        "*.cts"
      ];
    };
  };
}
