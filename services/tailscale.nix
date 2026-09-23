_: {
  flake.nixosModules.tailscale = {config, ...}: {
    sops.secrets."tailscale/authkey" = {
      sopsFile = ../secrets/sorbet/tailscale;
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

    networking.firewall = {
      trustedInterfaces = ["tailscale0"];
      allowedUDPPorts = [config.services.tailscale.port];
    };
  };
}
