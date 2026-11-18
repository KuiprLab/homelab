{lib, ...}: {
  options.flake.sorbetTraefikLabels = lib.mkOption {
    type = lib.types.functionTo (lib.types.functionTo (lib.types.attrsOf lib.types.str));
    description = ''
      Container labels for one private vhost on the sorbet edge: router, TLS,
      service port and the login gate. Resource name first, then its vhost.
    '';
  };
}
