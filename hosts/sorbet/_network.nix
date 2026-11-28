{constants}: {lib, ...}: {
  networking = {
    useDHCP = false;
    interfaces."${constants.lanInterface}" = {
      wakeOnLan.enable = true;
      ipv4.addresses = [
        {
          address = constants.lanIp;
          prefixLength = constants.lanPrefixLength;
        }
      ];
    };
    defaultGateway = constants.lanGateway;
    # LAN address, not loopback (query log attribution); mkOverride 50 beats resolvconf.
    nameservers = lib.mkOverride 50 [constants.lanIp];
    resolvconf.useLocalResolver = false;
  };
}
