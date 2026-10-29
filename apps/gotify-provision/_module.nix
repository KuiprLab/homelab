# Not containerized: a reconciler that drives the gotify container. Putting it
# in a container inverts the dependency.
#
# gotify-provision -- reconcile Gotify applications, tokens and icons.
#
# Gotify keeps applications and tokens as SQLite rows, so they cannot be
# declared; the script in this directory creates them and writes the tokens to
# its state directory. Called from services/monitoring/gotify-provision.nix,
# which owns the list of applications and the URL of the instance.
#
# The desired state is passed as environment variables; the script reads the
# admin password from the sops-backed GOTIFY_ADMIN_ENV_FILE.
{
  apps,
  baseUrl,
  gotifyDeps ? [],
  defineAdminSecret ? false,
  # Owns the applications. The same username as the Authelia user;
  # GOTIFY_OIDC_LINK_BY_USERNAME=true links the OIDC identity to it.
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
