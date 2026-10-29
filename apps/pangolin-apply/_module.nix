# pangolin-apply -- idempotent bootstrap of pangolin's server-side state.
#
# Pangolin keeps the org, the tunnel sites and the IdP registration in SQLite
# rows. Anything created here therefore has to be created imperatively, once,
# against a running API. That is the whole reason this lives in apps/: the
# script is business logic over pangolin's HTTP API, not declarative config.
#
# The identifiers it needs (org id/name/subnets, dashboard domain, OIDC issuer,
# site list) are declared once in services/infrastructure/pangolin.nix as
# flake.pangolinServer and injected by flake-module.nix, so the apply step and
# the generated config.yml cannot drift apart.
#
# Called with the pangolinServer attrset; returns the NixOS module.
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

  # Authelia's `pangolin` client hardcodes the redirect URL, which embeds the
  # idpId assigned above. 1 on a fresh database; the script only warns when a
  # re-registered IdP got a different one.
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

      # Admin credentials + one newt secret per site.
      EnvironmentFile = config.sops.secrets."pangolin-apply".path;
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "15s";
      ExecStart = lib.getExe pangolin-apply;
    };
  };
}
