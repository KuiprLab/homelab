{
  apps,
  baseUrl,
  gotifyDeps ? [],
  defineAdminSecret ? false,
  # Same name as the Authelia user; GOTIFY_OIDC_LINK_BY_USERNAME links the two.
  provisionUser ? "daniel",
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  provision = pkgs.callPackage ./_package.nix {};
in {
  sops.secrets = lib.optionalAttrs defineAdminSecret {
    "gotify/admin" = {
      sopsFile = ../../secrets/shared/gotify-admin.env;
      format = "dotenv";
      key = "";
      owner = "root";
    };
  };

  systemd.services.gotify-provision = {
    description = "Reconcile Gotify applications and tokens";
    after = ["network-online.target"] ++ gotifyDeps;
    wants = ["network-online.target"] ++ gotifyDeps;

    environment = {
      GOTIFY_BASE_URL = baseUrl;
      GOTIFY_APPS_JSON = builtins.toJSON apps;
      GOTIFY_USER_NAME = provisionUser;
      GOTIFY_ADMIN_ENV_FILE = config.sops.secrets."gotify/admin".path;
    };

    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "gotify-provision";
      StateDirectoryMode = "0700";
      ExecStart = lib.getExe provision;
    };
  };

  systemd.timers.gotify-provision = {
    description = "Reconcile Gotify applications every five minutes";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitActiveSec = "5min";
      Persistent = true;
    };
  };
}
