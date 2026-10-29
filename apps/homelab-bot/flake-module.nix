_: {
  perSystem = {pkgs, ...}: {
    packages.homelab-bot = pkgs.callPackage ./_package.nix {nodejs = pkgs.nodejs_26;};

    devShells.homelab-bot = pkgs.mkShell {
      packages = [
        pkgs.nodejs_26
        pkgs.typescript-language-server
      ];

      shellHook = ''
        echo "homelab-bot -- node $(node --version), npm $(npm --version)"
        echo
        echo "  npm install         deps into ./node_modules (gitignored)"
        echo "  npm run dev         run from src/, restart on change (.env)"
        echo "  npm run typecheck   tsc --noEmit"
        echo "  npm run build       tsc -> dist/"
        echo "  nix build .#homelab-bot"
        echo
      '';
    };
  };

  flake.nixosModules.homelab-bot = import ./_module.nix;
}
