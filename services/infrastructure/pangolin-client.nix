_: {
  flake.nixosModules.pangolinClient = {
    config,
    lib,
    pkgs,
    ...
  }: {
    # Machine client credentials from Clients -> Machines in the dashboard.
    sops.secrets."pangolin/client" = {
      sopsFile = ../../secrets/sorbet/pangolin-client.env;
      format = "dotenv";
      key = "";
      owner = "root";
      mode = "0400";
      restartUnits = ["pangolin-client.service"];
    };

    boot.kernelModules = ["wireguard"];

    systemd.services.pangolin-client = {
      description = "Pangolin machine client for private resources";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target" "sops-install-secrets.service"];
      wants = ["network-online.target"];
      serviceConfig = {
        # The CLI reads PANGOLIN_CLIENT_ID/SECRET/ENDPOINT from the environment
        # on purpose, so no secret reaches argv. No resource here uses an alias,
        # so the client must not take over resolv.conf: Technitium owns DNS.
        EnvironmentFile = config.sops.secrets."pangolin/client".path;
        ExecStart = "${lib.getExe pkgs.pangolin-cli} up --attach --override-dns=false";
        Restart = "always";
        RestartSec = "10s";
      };
    };
  };
}
