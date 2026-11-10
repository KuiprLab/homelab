{
  baseUrl,
  clientsSecretName ? "pocketid/clients",
  envSecretName ? "pocketid/pocketid.env",
  pocketidDeps ? ["podman-pocketid.service"],
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  provision = pkgs.callPackage ./_package.nix {};
in {
  systemd.services.pocketid-provision = {
    description = "Reconcile Pocket ID OIDC clients";
    wantedBy = ["multi-user.target"];
    after = ["network-online.target"] ++ pocketidDeps;
    wants = ["network-online.target"];
    requires = pocketidDeps;

    environment = {
      POCKET_ID_API_URL = baseUrl;
      POCKET_ID_CLIENTS_FILE = (lib.getAttr clientsSecretName config.sops.secrets).path;
      POCKET_ID_ENV_FILE = (lib.getAttr envSecretName config.sops.secrets).path;
    };

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "15s";
      ExecStart = lib.getExe provision;
    };
  };
}
