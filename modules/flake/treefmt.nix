# One formatter for the whole tree.
#
# In a monorepo "run the right formatter for this file type" has to be a single
# command, or it quietly stops happening the moment a second language lands.
# treefmt-nix owns the extension -> formatter mapping and wires up both
# `nix fmt` and a `treefmt` flake check from one declaration.
#
# Adding a language later is one line here and nothing anywhere else.
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
        alejandra.enable = true; # nix
        shfmt.enable = true; # shell
        prettier.enable = true; # typescript
      };

      # scripts/import-music is bash with no .sh suffix, so the default
      # shfmt globs miss it.
      settings.formatter.shfmt.includes = ["scripts/import-music"];

      # prettier also claims md, json, yaml and js by default, which would
      # reformat the README and every workflow in one go. Scoped to TypeScript
      # until that churn is worth taking deliberately -- drop this mkForce to
      # let it have the whole tree.
      settings.formatter.prettier.includes = lib.mkForce [
        "*.ts"
        "*.mts"
        "*.cts"
      ];

      # Waiting on their first app:
      #   programs.gofmt.enable = true;
      #   programs.rustfmt.enable = true;
    };
  };
}
