{lib, ...}: {
  options.flake.constants = lib.mkOption {
    type = lib.types.attrsOf lib.types.raw;
    description = ''
      Host, network and domain values that several modules need. One definition
      so a LAN address or a bridge gateway is never restated in a service file.
    '';
  };

  config.flake.constants = import ./_constants.nix;
}
