# The only file in this directory import-tree picks up. Its siblings are
# prefixed with _ so they are skipped, and are pulled in from here instead --
# one place that says how this app is built and run.
{config, ...}: {
  # Values come from flake.pangolinServer, declared next to the config they
  # belong to in services/infrastructure/pangolin.nix.
  flake.eclairNixosModules.pangolin-apply = import ./_module.nix {
    inherit
      (config.flake.pangolinServer)
      apiUrl
      dashboardDomain
      oidcIssuer
      orgId
      orgName
      orgSubnet
      orgUtilitySubnet
      sites
      ;
  };
}
