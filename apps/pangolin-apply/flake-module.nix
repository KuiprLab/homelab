{config, ...}: {
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
