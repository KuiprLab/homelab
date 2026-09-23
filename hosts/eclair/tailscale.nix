# Tailscale for eclair VPS — joins tailnet, no subnet advertising.
# Uses a separate auth key secret from sorbet's.
_: {
  flake.eclairNixosModules.eclairTailscale = {config, ...}: {
    sops.secrets."tailscale/authkey" = {
      sopsFile = ../../secrets/eclair/tailscale;
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
        "--accept-routes=false"
      ];
    };

    networking.firewall.trustedInterfaces = ["tailscale0"];
  };
}
