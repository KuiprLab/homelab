_: {
  flake.nixosModules.tailscale = {
    config,
    pkgs,
    ...
  }: {
    sops.secrets."tailscale/authkey" = {
      sopsFile = ../../secrets/sorbet/tailscale;
      format = "binary";
      key = "";
      owner = "root";
    };

    services.tailscale = {
      enable = true;
      openFirewall = true;
      authKeyFile = config.sops.secrets."tailscale/authkey".path;
      extraUpFlags = [
        "--accept-dns=false"
        "--accept-routes=true"
        "--advertise-routes=192.168.0.0/24"
      ];
    };

    # UDP throughput optimization for subnet routers/exit nodes
    # https://tailscale.com/kb/1320/performance-best-practices#linux-optimizations-for-subnet-routers-and-exit-nodes
    systemd.services.tailscale-udp-gro-forwarding = {
      description = "Tailscale UDP GRO forwarding optimization";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      wantedBy = ["multi-user.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "tailscale-udp-gro-forwarding" ''
          NETDEV=$(${pkgs.iproute2}/bin/ip -o route get 8.8.8.8 | cut -f 5 -d " ")
          ${pkgs.ethtool}/bin/ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off
        '';
      };
    };

    networking.firewall = {
      trustedInterfaces = ["tailscale0"];
      allowedUDPPorts = [config.services.tailscale.port];
    };
  };
}
