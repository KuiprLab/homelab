# Reconcile Gotify applications and tokens.
#
# Gotify has no declarative app/token config; applications are SQLite rows. The
# reconciler in apps/gotify-provision creates the applications listed below on
# every host and writes their tokens to its state dir. Tokens never enter git.
#
# Icons are names from selfh.st/icons (or full URLs). The reconciler resolves
# the name to https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/<name>.png and
# uploads it; a reference file and a hash prevent a re-upload on every run.
#
# A failed run exits 0: a missing Gotify must not abort a deployment. The
# timer retries every five minutes.
_: let
  mkProvision = import ../../apps/gotify-provision/_module.nix;
in {
  flake.nixosModules.gotifyProvision = mkProvision {
    apps = {
      comin-sorbet = {
        icon = "nixos";
      };
      beets = {
        icon = "beets";
      };
      healthchecks = {
        icon = "healthchecks";
      };
      beszel = {
        icon = "beszel";
      };
      crowdsec = {
        icon = "crowdsec";
      };
    };
    baseUrl = "http://127.0.0.1:8085";
    gotifyDeps = ["podman-gotify.service"];
  };

  flake.eclairNixosModules.gotifyProvision = mkProvision {
    apps = {
      comin-eclair = {
        icon = "nixos";
      };
    };
    baseUrl = "https://gotify.ext.kuipr.de";
    defineAdminSecret = true;
  };
}
