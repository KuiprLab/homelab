_: {
  flake.gatusEndpoints = [
    {
      name = "DNS";
      group = "Network";
      url = "192.168.0.85";
      dns = {
        query-name = "has.int.kuipr.de";
        query-type = "A";
      };
      conditions = ["[DNS_RCODE] == NOERROR"];
      alerts = [{type = "discord";}];
    }
  ];

  flake.nixosModules.dnsDhcp = {
    lib,
    pkgs,
    ...
  }: let
    serverIp = "192.168.0.85";
    networkInterface = "enp0s31f6";

    # Fallback dnsmasq config — plain DNS forwarding + DHCP, no split-horizon.
    # Activated automatically if the main dnsmasq service fails, so you can
    # still reach the server (and it can reach GitHub etc.) to fix things.
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
    # dnsmasq — handles both DHCP and DNS (.int.kuipr.de wildcard)
    # -------------------------------------------------------------------------
    services.dnsmasq = {
      enable = true;
      settings = {
        interface = [networkInterface];
        bind-interfaces = true;
        dns-forward-max = 300;
        address = "/.int.kuipr.de/${serverIp}";
        server = [
          #TODO: Find non-US alternative that isn't Quad9
          "1.1.1.1"
          "1.1.2.2"
          "8.8.8.8"
          "8.8.4.4"
        ];

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
