_: let
  serverIp = "192.168.0.85";
  zone = "int.kuipr.de";

  apiUrl = "http://127.0.0.1:5380/api";

  blocklists = [
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
    "https://big.oisd.nl"
  ];

  settings = {
    dnsServerDomain = "sorbet.${zone}";
    # Never bind 0.0.0.0: aardvark-dns and incus' dnsmasq hold :53 on their bridges.
    dnsServerLocalEndPoints = "${serverIp}:53,127.0.0.1:53";
    forwarders = "1.1.1.1,9.9.9.9";
    forwarderProtocol = "Udp";
    logQueries = true;
    webServiceLocalAddresses = "127.0.0.1";
    enableBlocking = true;
    blockingType = "AnyAddress";
    blockListUrls = builtins.concatStringsSep "," blocklists;
    blockListUpdateIntervalHours = 24;
  };

  sso = {
    authority = "https://auth.ext.kuipr.de";
    clientId = "technitium";
    scopes = "openid|profile|email|groups";
    groupMap = "admin|Administrators";
  };

  dhcpScope = {
    name = "lan";
    startingAddress = "192.168.0.2";
    endingAddress = "192.168.0.254";
    subnetMask = "255.255.255.0";
    # The API rejects hours outside 0-23.
    leaseTimeDays = 1;
    leaseTimeHours = 0;
    routerAddress = "192.168.0.1";
  };

  reservedLeases = [
    {
      hardwareAddress = "18:31:bf:b7:fd:3f";
      ipAddress = serverIp;
      hostName = "sorbet";
    }
    {
      hardwareAddress = "74:56:3c:30:fc:b7";
      ipAddress = "192.168.0.5";
      hostName = "tiramisu";
    }
  ];
in {
  flake.pangolinVirtualHosts."technitium" = {
    site = "sorbet";
    name = "Technitium DNS";
    subdomain = "technitium.int.kuipr.de";
    port = 5380;
  };

  flake.nixosModules.technitium = {config, ...}: {
    imports = [
      (import ../apps/technitium-converge/_module.nix {
        inherit
          apiUrl
          dhcpScope
          reservedLeases
          serverIp
          settings
          sso
          zone
          ;
      })
    ];

    sops.secrets."technitium.env" = {
      sopsFile = ../secrets/sorbet/technitium.env;
      format = "dotenv";
      key = "";
      owner = "root";
    };

    services.technitium-dns-server.enable = true;
    # DHCP must not start before enp0s31f6 has its address; the module only orders against network.target.
    systemd.services.technitium-dns-server = {
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # Only read while Technitium creates auth.config on a fresh state dir.
      serviceConfig.EnvironmentFile = config.sops.secrets."technitium.env".path;
    };
  };
}
