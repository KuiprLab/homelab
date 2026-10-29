_: {
  flake.nixosModules.dnsFallback = {
    lib,
    pkgs,
    ...
  }: let
    serverIp = "192.168.0.85";
    networkInterface = "enp0s31f6";

    fallbackDnsmasqConf = pkgs.writeText "dnsmasq-fallback.conf" ''
      interface=${networkInterface}
      bind-interfaces

      server=1.1.1.1
      server=9.9.9.9

      dhcp-range=192.168.0.2,192.168.0.254,255.255.255.0,24h
      dhcp-option=option:router,192.168.0.1
      dhcp-option=option:dns-server,9.9.9.9

      dhcp-host=18:31:bf:b7:fd:3f,sorbet,${serverIp},infinite
      dhcp-host=74:56:3c:30:fc:b7,tiramisu,192.168.0.5,infinite

      no-resolv
      log-dhcp
    '';
  in {
    systemd.services.technitium-dns-server.unitConfig = {
      OnFailure = ["dnsmasq-fallback.service"];
      # Restart=always never reaches the failed state, so OnFailure would never fire.
      StartLimitIntervalSec = 120;
      StartLimitBurst = 6;
    };

    systemd.services.dnsmasq-fallback = {
      description = "Fallback DNS/DHCP (plain upstream forwarding, no ad blocking)";
      wantedBy = lib.mkForce [];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      unitConfig = {
        Conflicts = ["technitium-dns-server.service"];
        Before = ["technitium-dns-server.service"];
      };

      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=${fallbackDnsmasqConf} --pid-file=/run/dnsmasq-fallback.pid";
        ExecStop = "${pkgs.coreutils}/bin/kill -TERM $MAINPID";
        Restart = "on-failure";
        RestartSec = "5s";
        ExecStartPost = "${pkgs.coreutils}/bin/echo 'WARNING: dnsmasq-fallback is active — technitium failed. DNS is plain upstream only.'";
      };
    };

    networking = {
      firewall = {
        allowedTCPPorts = [53];
        allowedUDPPorts = [
          53
          67
          68
        ];
      };
    };

    # Technitium binds :53 itself.
    services.resolved.enable = lib.mkForce false;
  };
}
