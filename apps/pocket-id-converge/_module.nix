{
  apiUrl,
  appUrl,
  baseUrl,
  clients,
  users,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  converge = pkgs.callPackage ./_package.nix {};
in {
  systemd.services.pocket-id-converge = {
    description = "Converge Pocket ID OIDC clients through its REST API";
    wantedBy = ["multi-user.target"];
    # Only After: a hard dependency turns any container restart into a cancelled run.
    after = ["podman-pocket-id.service"];

    environment = {
      POCKET_ID_API_URL = apiUrl;
      POCKET_ID_APP_URL = appUrl;
      POCKET_ID_BASE_URL = baseUrl;
      POCKET_ID_CLIENTS_JSON = builtins.toJSON clients;
      POCKET_ID_USERS_JSON = builtins.toJSON users;
      POCKET_ID_ENV_FILE = config.sops.secrets."pocket-id/env".path;
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = lib.getExe converge;
    };
  };
}
