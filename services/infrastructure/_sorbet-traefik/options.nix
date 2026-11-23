{lib, ...}: {
  options.flake.extVhosts = lib.mkOption {
    default = {};
    description = ''
      Derived from pangolinVirtualHosts, not set by hand: the public (ext)
      vhosts. Technitium answers these names with the LAN address, so the edge
      serves them locally and Technitium holds one small zone per name.
    '';
    type = lib.types.attrsOf lib.types.raw;
  };

  options.flake.sorbetTraefikLabels = lib.mkOption {
    type = lib.types.functionTo (lib.types.functionTo (lib.types.attrsOf lib.types.str));
    description = ''
      Container labels for one private vhost on the sorbet edge: router, TLS,
      service port and the login gate. Resource name first, then its vhost.
    '';
  };
}
