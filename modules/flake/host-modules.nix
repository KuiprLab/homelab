{lib, ...}: {
  options.flake.hostModules = lib.mkOption {
    type = lib.types.attrsOf lib.types.raw;
    default = {};
    description = ''
      NixOS modules that every host applies. A module belongs here when it must
      run on sorbet and on eclair alike; host-only modules stay in
      flake.nixosModules (sorbet) or flake.eclairNixosModules (eclair).
    '';
  };
}
