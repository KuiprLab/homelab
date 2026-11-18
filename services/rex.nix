{inputs, ...}: let
  mkRexModule = user: _: {
    imports = [inputs.rex.nixosModules.default];

    services.rex = {
      enable = true;
      inherit user;
      group = "rex";
      allowAnonymous = false;
    };
  };

  # Rex embeds Tailscale (tsnet): no tailscaled on the host, no tailscale0, no
  # 100.64.0.0/10 routes, so pangolin's CGNAT site subnets stay untouched.
  # sops-nix ignores `key` for dotenv/binary/ini and hands over the whole file,
  # which would pass `TS_AUTHKEY=...` to tsnet as the key. yaml extracts it.
  mkRexTailscale = {
    hostname,
    sopsFile,
  }: {config, ...}: {
    sops.secrets."rex-tailscale-authkey" = {
      inherit sopsFile;
      format = "yaml";
      key = "TS_AUTHKEY";
      owner = "root";
      restartUnits = ["rex.service"];
    };

    services.rex.tailscale = {
      enable = true;
      inherit hostname;
      authKeyFile = config.sops.secrets."rex-tailscale-authkey".path;
    };
  };
in {
  flake = {
    nixosModules.rex = {
      imports = [
        (mkRexModule "daniel")
        (mkRexTailscale {
          hostname = "sorbet-rex";
          sopsFile = ../secrets/sorbet/tailscale.yaml;
        })
      ];
    };
    eclairNixosModules.rex = {
      imports = [
        (mkRexModule "root")
        (mkRexTailscale {
          hostname = "eclair-rex";
          sopsFile = ../secrets/eclair/tailscale.yaml;
        })
      ];
    };
  };
}
