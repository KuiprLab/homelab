_: {
  flake.nixosModules.dnsDhcp = {
    lib,
    pkgs,
    ...
  }: let
    serverIp = "192.168.0.85";
    networkInterface = "enp0s31f6";

    # Fallback dnsmasq config: plain DNS forwarding + DHCP, no split-horizon.
    fallbackDnsmasqConf = pkgs.writeText "dnsmasq-fallback.conf" ''
      interface=${networkInterface}
      bind-interfaces

      # Pure upstream forwarding — no custom address overrides
      server=1.1.1.1
      server=8.8.8.8

      # Hand out IPs and tell clients to use 9.9.9.9 directly
      dhcp-range=192.168.0.2,192.168.0.254,255.255.255.0,24h
      dhcp-option=option:router,192.168.0.1
      dhcp-option=option:dns-server,9.9.9.9

      # Keep the static lease for the server itself
      dhcp-host=18:31:bf:b7:fd:3f,sorbet,${serverIp},infinite
      dhcp-host=74:56:3c:30:fc:b7,tiramisu,192.168.0.5,infinite

      no-resolv
      log-dhcp
    '';
  in {
    # -------------------------------------------------------------------------
    # dnsmasq DHCP + pure LAN forwarding to the Pi-hole.
    # -------------------------------------------------------------------------
    services.dnsmasq = {
      enable = true;
      settings = {
        interface = [networkInterface];
        bind-interfaces = true;
        dns-forward-max = 300;
        # Single upstream: the local Pi-hole container (published on
        # loopback:5353). Every LAN lookup gets ad blocking and query
        # logging. Loopback publish keeps the stack private to the host.
        server = ["127.0.0.1#5353"];
        # Pi-hole is the only caching layer, so repeated
        # lookups stay visible (and attributable) in the FTL query log
        # instead of being absorbed by dnsmasq.
        cache-size = 0;
        # Tag forwarded queries with the requesting client's full address
        # (EDNS Client Subnet).
        add-subnet = "32,128";

        dhcp-range = "192.168.0.2,192.168.0.254,255.255.255.0,24h";
        dhcp-option = [
          "option:router,192.168.0.1"
          "option:dns-server,${serverIp}"
        ];

        dhcp-host = "18:31:bf:b7:fd:3f,sorbet,${serverIp},infinite";

        no-resolv = true;
        log-dhcp = true;
      };
    };

    # -------------------------------------------------------------------------
    # Fallback: starts automatically when dnsmasq fails.
    # Runs dnsmasq on a separate pidfile so it doesn't collide with a
    # partially-started main instance.
    # -------------------------------------------------------------------------
    systemd.services.dnsmasq.unitConfig.OnFailure = ["dnsmasq-fallback.service"];

    systemd.services.dnsmasq-fallback = {
      description = "Fallback DNS/DHCP (plain upstream forwarding, no split-horizon)";
      # Don't start at boot — only triggered via OnFailure above.
      wantedBy = lib.mkForce [];
      after = ["network.target"];

      serviceConfig = {
        Type = "simple";
        # Use a separate pidfile so we never collide with the main instance.
        ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=${fallbackDnsmasqConf} --pid-file=/run/dnsmasq-fallback.pid";
        ExecStop = "${pkgs.coreutils}/bin/kill -TERM $MAINPID";
        Restart = "on-failure";
        RestartSec = "5s";
        # Announce via a log message so you notice it in journalctl
        ExecStartPost = "${pkgs.coreutils}/bin/echo 'WARNING: dnsmasq-fallback is active — main dnsmasq failed. DNS is plain upstream only.'";
      };
    };

    # Open firewall ports (same as before)
    networking = {
      firewall = {
        allowedTCPPorts = [53];
        allowedUDPPorts = [
          53
          67
          68
        ];
        interfaces."tailscale0".allowedTCPPorts = [53];
        interfaces."tailscale0".allowedUDPPorts = [53];
      };
    };

    # Disable systemd-resolved to avoid port 53 conflict
    services.resolved.enable = lib.mkForce false;
  };
}
