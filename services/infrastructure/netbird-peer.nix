# NetBird client (peer) for sorbet: the routing peer for the home LAN.
#
# Clients off-LAN resolve *.int.kuipr.de to 192.168.0.85 (netbird DNS
# zone → Pi-hole), and traffic rides this peer's route before nftables
# masquerades it onto the LAN. Hosts/dnsmasq keep serving the LAN
# wildcard independently.
#
# Enrollment (one-time, after a control-plane deploy):
#   netbird up --management-url https://netbird.kuipr.de --setup-key <servers key>
# The daemon persists state under /var/lib/netbird; later boots connect
# on their own.
_: {
  flake.nixosModules.netbirdClient = _: {
    services.netbird = {
      clients.default = {
        interface = "wt0";
        port = 51820;
      };
      # Routing peer: IP forwarding + loose rp_filter (netbird nixos module).
      useRoutingFeatures = "server";
    };

    # Overlay-arriving requests (from roaming peers and eclair's caddy) hit
    # the LAN-bound LAN services (caddy :443, hub :8091, authelia :9091,
    # navidrome :4533) and dnsmasq :53. Everything else on wt0 stays shut.
    networking.firewall.interfaces."wt0" = {
      allowedTCPPorts = [
        80
        443
        4533
        8091
        9091
      ];
      allowedUDPPorts = [53];
    };

    # masquerade overlay-sourced traffic onto the LAN.
    networking.nat = {
      enable = true;
      internalInterfaces = ["wt0"];
      externalInterface = "enp0s31f6";
    };
  };
}
