# Fallback DNS + DHCP for when Technitium is down.
#
# Technitium (services/technitium.nix) is the only LAN DNS and DHCP authority.
# dnsmasq is kept as a plain-forwarding lifeboat: if technitium-dns-server
# crash-loops into the failed state, OnFailure starts this instance, which keeps
# handing out leases and resolving names without ad blocking (public resolvers,
# and 9.9.9.9 as the client resolver option).
#
# It is not a second DNS layer: nothing forwards to it while Technitium runs.
# Starting Technitium again stops this unit (Conflicts), so the handback needs
# no manual step beyond `systemctl restart technitium-dns-server`.
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

      # Pure upstream forwarding — no ad blocking, no split-horizon.
      server=1.1.1.1
      server=9.9.9.9

      # Same subnet as the Technitium scope, but clients are told to use a
      # public resolver: this instance must not look like the normal resolver.
      dhcp-range=192.168.0.2,192.168.0.254,255.255.255.0,24h
      dhcp-option=option:router,192.168.0.1
      dhcp-option=option:dns-server,9.9.9.9

      # Static leases for the infrastructure hosts, mirroring the Technitium
      # scope so the hosts keep their addresses across a fallback.
      dhcp-host=18:31:bf:b7:fd:3f,sorbet,${serverIp},infinite
      dhcp-host=74:56:3c:30:fc:b7,tiramisu,192.168.0.5,infinite

      no-resolv
      log-dhcp
    '';
  in {
    systemd.services.technitium-dns-server.unitConfig = {
      OnFailure = ["dnsmasq-fallback.service"];
      # Restart=always alone never lets the unit reach the failed state, so
      # OnFailure would never fire. A crash-loop (6 starts inside two minutes)
      # is treated as a failure and hands the LAN over to the fallback.
      StartLimitIntervalSec = 120;
      StartLimitBurst = 6;
    };

    systemd.services.dnsmasq-fallback = {
      description = "Fallback DNS/DHCP (plain upstream forwarding, no ad blocking)";
      # Only ever triggered by OnFailure above.
      wantedBy = lib.mkForce [];
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # Starting Technitium takes the LAN back automatically.
      unitConfig = {
        Conflicts = ["technitium-dns-server.service"];
        Before = ["technitium-dns-server.service"];
      };

      serviceConfig = {
        Type = "simple";
        # Separate pidfile so a partly-started instance can never collide.
        ExecStart = "${pkgs.dnsmasq}/bin/dnsmasq --keep-in-foreground --conf-file=${fallbackDnsmasqConf} --pid-file=/run/dnsmasq-fallback.pid";
        ExecStop = "${pkgs.coreutils}/bin/kill -TERM $MAINPID";
        Restart = "on-failure";
        RestartSec = "5s";
        # Make the takeover loud in the journal.
        ExecStartPost = "${pkgs.coreutils}/bin/echo 'WARNING: dnsmasq-fallback is active — technitium failed. DNS is plain upstream only.'";
      };
    };

    # Ports for the DNS/DHCP service (Technitium binds them; the fallback needs
    # the same ones). 5380 stays closed: caddy reaches the console via loopback.
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

    # Technitium binds :53 itself, so systemd-resolved must not.
    services.resolved.enable = lib.mkForce false;
  };
}
