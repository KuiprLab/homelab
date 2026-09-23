# One formatter for the whole tree.
#
# In a monorepo "run the right formatter for this file type" has to be a single
# command, or it quietly stops happening the moment a second language lands.
# treefmt-nix owns the extension -> formatter mapping and wires up both
# `nix fmt` and a `treefmt` flake check from one declaration.
#
# Adding a language later is one line here and nothing anywhere else.
{inputs, ...}: {
  imports = [inputs.treefmt-nix.flakeModule];

  perSystem = _: {
    treefmt = {
      projectRootFile = "flake.nix";

      programs = {
        alejandra.enable = true; # nix
        shfmt.enable = true; # shell
      };

      # scripts/import-music is bash with no .sh suffix, so the default
      # shfmt globs miss it.
      settings.formatter.shfmt.includes = ["scripts/import-music"];

      # Waiting on apps/ -- enable next to the first daemon that needs one:
      #   programs.gofmt.enable = true;
      #   programs.rustfmt.enable = true;
      #   programs.prettier.enable = true;  # md, json, yaml, js
    };
  };
}
