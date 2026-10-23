{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule (finalAttrs: {
  pname = "newt";
  version = "1.19.0";

  src = fetchFromGitHub {
    owner = "fosrl";
    repo = "newt";
    tag = finalAttrs.version;
    hash = "sha256-V5VDETiBHBFno5WRHmnhMv/UQ/ewGrDU8/8l75qqL8E=";
  };

  vendorHash = "sha256-g9OiXbL+mW5uDsOig4SIU90j8xsulf1zx+WSxKXuPbk=";

  ldflags = [
    "-s"
    "-w"
    "-X=main.newtVersion=${finalAttrs.version}"
  ];

  doCheck = false;
  doInstallCheck = false;

  __structuredAttrs = true;

  meta = {
    description = "Tunneling client for Pangolin";
    homepage = "https://github.com/fosrl/newt";
    changelog = "https://github.com/fosrl/newt/releases/tag/${finalAttrs.src.tag}";
    license = lib.licenses.agpl3Only;
    mainProgram = "newt";
  };
})
