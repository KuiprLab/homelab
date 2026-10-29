{
  apiUrl,
  dashboardDomain,
  oidcIssuer,
  orgId,
  orgName,
  orgSubnet,
  orgUtilitySubnet,
  sites,
}: {
  config,
  lib,
  pkgs,
  ...
}: let
  pangolin-apply = pkgs.callPackage ./_package.nix {};

  # Authelia's `pangolin` client hardcodes the redirect URL (idpId 1 on a fresh DB).
  expectedRedirect = "https://${dashboardDomain}/auth/idp/1/oidc/callback";
in {
  sops.secrets."pangolin-apply" = {
    sopsFile = ../../secrets/eclair/pangolin-apply.env;
    format = "dotenv";
    key = "";
  };

  systemd.services."pangolin-apply" = {
    description = "Pangolin org/site/IdP bootstrap (idempotent)";
    wantedBy = ["multi-user.target"];
    after = ["podman-pangolin.service"];
    requires = ["podman-pangolin.service"];

    environment = {
      PANGOLIN_API_URL = apiUrl;
      PANGOLIN_ORG_ID = orgId;
      PANGOLIN_ORG_NAME = orgName;
      PANGOLIN_ORG_SUBNET = orgSubnet;
      PANGOLIN_ORG_UTILITY_SUBNET = orgUtilitySubnet;
      PANGOLIN_OIDC_ISSUER = oidcIssuer;
      PANGOLIN_EXPECTED_REDIRECT = expectedRedirect;
      PANGOLIN_SITES = builtins.toJSON sites;
    };

    serviceConfig = {
      Type = "oneshot";
      RuntimeDirectory = "pangolin-apply";
      RuntimeDirectoryMode = "0700";

      EnvironmentFile = config.sops.secrets."pangolin-apply".path;
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "15s";
      ExecStart = lib.getExe pangolin-apply;
    };
  };
}
