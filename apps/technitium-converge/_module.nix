{
  apiUrl,
  dhcpScope,
  reservedLeases,
  serverIp,
  settings,
  sso,
  zone,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  converge = pkgs.callPackage ./_package.nix {};
in {
  systemd.services.technitium-converge = {
    description = "Converge Technitium DNS/DHCP state through its REST API";
    wantedBy = ["multi-user.target"];
    after = ["technitium-dns-server.service"];
    requires = ["technitium-dns-server.service"];

    environment = {
      TECHNITIUM_API_URL = apiUrl;
      TECHNITIUM_ZONE = zone;
      TECHNITIUM_SERVER_IP = serverIp;
      TECHNITIUM_DESIRED_JSON = builtins.toJSON {
        inherit
          dhcpScope
          reservedLeases
          settings
          sso
          ;
      };
      TECHNITIUM_ENV_FILE = config.sops.secrets."technitium.env".path;
    };

    serviceConfig = {
      Type = "oneshot";
      # Holds the SSO config hash; changed ExecStart restarts the unit on switch.
      RemainAfterExit = true;
      StateDirectory = "technitium-converge";
      ExecStart = lib.getExe converge;
    };
  };
}
