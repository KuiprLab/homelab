{inputs, ...}: {
  flake.hostModules.rex = {
    config,
    lib,
    ...
  }: let
    cfg = config.homelab.rex;
  in {
    imports = [inputs.rex.nixosModules.default];

    config = lib.mkIf cfg.enable {
      # sops-nix hands over the whole dotenv file when `key` is empty, which
      # passes `TS_AUTHKEY=...` to tsnet as the key. yaml extracts the value.
      sops.secrets."rex-tailscale-authkey" = {
        inherit (cfg) sopsFile;
        format = "yaml";
        key = "TS_AUTHKEY";
        owner = "root";
        restartUnits = ["rex.service"];
      };

      # Rex embeds Tailscale (tsnet): no tailscaled on the host, no tailscale0,
      # no 100.64.0.0/10 routes, so pangolin's CGNAT site subnets stay untouched.
      services.rex = {
        enable = true;
        inherit (cfg) user;
        group = "rex";
        allowAnonymous = false;
        tailscale = {
          enable = true;
          inherit (cfg) hostname;
          authKeyFile = config.sops.secrets."rex-tailscale-authkey".path;
        };
      };
    };
  };
}
