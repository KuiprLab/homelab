{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "tiny-cdn";
  version = (builtins.fromTOML (builtins.readFile ./Cargo.toml)).package.version;

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./src
      ./Cargo.toml
      ./Cargo.lock
    ];
  };

  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Signed-upload file CDN";
    mainProgram = "tiny-cdn";
    platforms = lib.platforms.unix;
  };
}
