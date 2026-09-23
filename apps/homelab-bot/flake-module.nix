# The only file in this directory import-tree picks up. Its siblings are
# prefixed with _ so they are skipped, and are pulled in from here instead --
# one place that says how this app is built, run and developed.
_: {
  perSystem = {pkgs, ...}: {
    packages.homelab-bot = pkgs.callPackage ./_package.nix {};

    # nix develop .#homelab-bot
    #
    # Or just cd into this directory: .envrc picks it up via direnv.
    #
    # nodejs here is the same derivation _package.nix builds with. That is the
    # point -- a package-lock.json written by a different npm is one Nix may
    # refuse, and that mismatch only ever shows up in CI.
    devShells.homelab-bot = pkgs.mkShell {
      packages = [
        pkgs.nodejs # node, npm, npx
        pkgs.typescript-language-server # editor LSP; tsc itself comes from the lockfile
      ];

      shellHook = ''
        echo "homelab-bot -- node $(node --version), npm $(npm --version)"
        echo
        echo "  npm install         deps into ./node_modules (gitignored)"
        echo "  npm run typecheck   tsc --noEmit"
        echo "  npm run build       tsc -> dist/"
        echo "  nix build .#homelab-bot"
        echo
      '';
    };
  };

  flake.nixosModules.homelab-bot = import ./_module.nix;
}
