{
  lib,
  buildNpmPackage,
  importNpmLock,
  makeWrapper,
  nodejs,
}:
buildNpmPackage {
  pname = "homelab-bot";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./src
      ./package.json
      ./package-lock.json
      ./tsconfig.json
    ];
  };

  # importNpmLock, not buildNodeModules: npmConfigHook needs the patched lock.
  npmDeps = importNpmLock.importNpmLock {
    npmRoot = ./.;
  };
  inherit (importNpmLock) npmConfigHook;

  inherit nodejs;

  nativeBuildInputs = [makeWrapper];

  postInstall = ''
    makeWrapper ${lib.getExe nodejs} "$out/bin/homelab-bot" \
      --add-flags "$out/lib/node_modules/homelab-bot/dist/index.js"

    makeWrapper ${lib.getExe nodejs} "$out/bin/homelab-bot-register" \
      --add-flags "$out/lib/node_modules/homelab-bot/dist/register-commands.js"
  '';

  meta = {
    description = "Discord bot for the kuipr homelab";
    mainProgram = "homelab-bot";
    platforms = lib.platforms.unix;
  };
}
