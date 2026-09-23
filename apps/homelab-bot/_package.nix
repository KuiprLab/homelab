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

  # Only these paths enter the store. Without the fileset, `src` would be the
  # whole directory -- and as apps/ grows, any unrelated edit anywhere near it
  # would change this derivation's hash and force a rebuild. Narrowing every
  # app's source is what keeps the binary cache useful in a monorepo.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./src
      ./package.json
      ./package-lock.json
      ./tsconfig.json
    ];
  };

  # importNpmLock derives every dependency hash from package-lock.json itself,
  # so there is no npmDepsHash to re-pin. Bumping a dependency is `npm install`
  # and commit the lockfile -- nothing in this file changes.
  # Note this is importNpmLock.importNpmLock, not importNpmLock.buildNodeModules:
  # npmConfigHook copies package.json/package-lock.json out of npmDeps, so it
  # needs the derivation holding the *patched* lockfile. buildNodeModules emits
  # a prebuilt node_modules alongside the original lock and pairs with
  # linkNodeModulesHook instead.
  npmDeps = importNpmLock.importNpmLock {
    npmRoot = ./.;
  };
  inherit (importNpmLock) npmConfigHook;

  inherit nodejs;

  nativeBuildInputs = [makeWrapper];

  # `npm run build` (tsc) emits ESM into dist/. package.json declares no bin
  # entries, so wrap the two entry points by hand rather than depending on npm
  # to guess them.
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
