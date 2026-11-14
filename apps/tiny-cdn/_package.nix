{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "tiny-cdn";
  version = "1.0.0";

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
