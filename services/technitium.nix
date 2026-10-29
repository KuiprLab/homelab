# Technitium DNS Server on sorbet: LAN resolver, ad/malware blocker and DHCP
# server for 192.168.0.0/24. One process is authoritative for both DNS and DHCP
# on the LAN; nothing forwards to a second resolver.
#
# The nixpkgs module (services.technitium-dns-server) only defines the unit; it
# has no configuration options. Everything else lives in Technitium's mutable
# state dir and is applied by technitium-converge.service through the REST API
# (apps/technitium-converge): forwarders, blocking, the int.kuipr.de zone, the
# DHCP scope. The unit writes the full desired state on boot and whenever this
# file changes; every call is an idempotent overwrite, not an append.
#
# Bootstrap: the unit passes the sops password as
# DNS_SERVER_ADMIN_PASSWORD, which Technitium only honours while it creates
# auth.config on a fresh state dir. The converge script still falls back to the
# built-in admin/admin login once, for a state dir created before this wiring.
#
# Consumers:
#   * DHCP hands 192.168.0.85 out as resolver for the LAN (option 6).
#   * Container workloads pin --dns=192.168.0.85, so their queries are logged
#     under their podman IP instead of aardvark's gateway address.
#   * *.int.kuipr.de resolves to sorbet (wildcard record in a primary zone),
#     where caddy terminates TLS.
#   * If the server crash-loops, dnsmasq takes over the LAN
#     (services/infrastructure/dns-fallback.nix).
_: let
  serverIp = "192.168.0.85";
  zone = "int.kuipr.de";

  # Local API. The web console is bound to loopback only; caddy serves it on
  # technitium.int.kuipr.de.
  apiUrl = "http://127.0.0.1:5380/api";

  # Declarative blocklist set. Edit here and redeploy; Technitium re-downloads
  # the lists itself every blockListUpdateIntervalHours.
  blocklists = [
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
    "https://big.oisd.nl"
  ];

  settings = {
    # SOA/NS name of this server inside the local zone.
    dnsServerDomain = "sorbet.${zone}";
    # Never bind the wildcard. podman's aardvark-dns and incus' dnsmasq hold
    # :53 on their bridge addresses, and a 0.0.0.0 bind (the Technitium
    # default) then fails with EADDRINUSE. These are the only two addresses
    # that need to answer: the LAN and the host itself.
    dnsServerLocalEndPoints = "${serverIp}:53,127.0.0.1:53";
    # Forwarding (not recursion): the upstream behaviour stays as it was.
    forwarders = "1.1.1.1,9.9.9.9";
    forwarderProtocol = "Udp";
    # Every query is logged: the dashboard is the blocking audit trail.
    logQueries = true;
    # Web console and REST API on loopback only. caddy serves
    # technitium.int.kuipr.de from there; nothing on the LAN reaches 5380.
    webServiceLocalAddresses = "127.0.0.1";
    enableBlocking = true;
    # AnyAddress answers 0.0.0.0/:: for blocked names (NULL blocking).
    blockingType = "AnyAddress";
    blockListUrls = builtins.concatStringsSep "," blocklists;
    blockListUpdateIntervalHours = 24;
  };

  # Authelia OIDC. The client is registered in the authelia sops config; the
  # secret is shared through secrets/sorbet/technitium.env.
  sso = {
    authority = "https://auth.ext.kuipr.de";
    clientId = "technitium";
    scopes = "openid|profile|email|groups";
    # Remote group -> Technitium group. `daniel` is in `admin` in authelia.
    groupMap = "admin|Administrators";
  };

  dhcpScope = {
    name = "lan";
    startingAddress = "192.168.0.2";
    endingAddress = "192.168.0.254";
    subnetMask = "255.255.255.0";
    # 24 h leases: the API rejects hours outside 0-23.
    leaseTimeDays = 1;
    leaseTimeHours = 0;
    routerAddress = "192.168.0.1";
  };

  # Static identities for the infrastructure hosts.
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
    # Ports are opened by services/infrastructure/dns-fallback.nix.
    # DHCP serves as soon as the scope exists, so the unit must not start before
    # enp0s31f6 has its address; the module only orders against network.target.
    systemd.services.technitium-dns-server = {
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # Only read while Technitium creates auth.config on a fresh state dir;
      # afterwards the password lives in auth.config.
      serviceConfig.EnvironmentFile = config.sops.secrets."technitium.env".path;
    };
  };
}
