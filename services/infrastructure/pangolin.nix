{
  lib,
  config,
  ...
}: let
  constants = import ./_pangolin/constants.nix;
  resources = import ./_pangolin/resources.nix {
    inherit lib;
    vhosts = config.flake.pangolinVirtualHosts;
    hostRoutes = config.flake.pangolinHostResources;
    exitNodes = config.flake.pangolinExitNodes;
    geoAllow = config.flake.pangolinGeoAllow;
    asnDeny = config.flake.pangolinAsnDeny;
    inherit (constants) sites tolerance;
  };
in {
  imports = [
    ./_pangolin/options.nix
    (import ./_pangolin/server.nix {inherit constants;})
    (import ./_pangolin/newt.nix {inherit resources;})
  ];

  config.flake = {
    pangolinRuleLabels = resources.ruleLabels;
    pangolinHealthcheckLabels = resources.healthcheckLabels;

    pangolinServer = {
      inherit
        (constants)
        apiUrl
        orgId
        orgName
        orgSubnet
        orgUtilitySubnet
        dashboardDomain
        oidcIssuer
        sites
        ;
      inherit (resources) standaloneHealthChecks;
    };
  };
}
