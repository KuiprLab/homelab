let
  baseDomain = "kuipr.de";
  lanIp = "192.168.0.85";
in {
  inherit baseDomain lanIp;

  intDomain = "int.${baseDomain}";
  extDomain = "ext.${baseDomain}";
  idDomain = "id.ext.${baseDomain}";

  lanInterface = "enp0s31f6";
  lanGateway = "192.168.0.1";
  lanNetmask = "255.255.255.0";
  lanPrefixLength = 24;
  lanDhcpStart = "192.168.0.2";
  lanDhcpEnd = "192.168.0.254";

  proxySubnet = "10.89.0.0/24";
  proxyDynamicRange = "10.89.0.128/25";
  proxyGateway = "10.89.0.1";
  podmanBridgeGateway = "10.88.0.1";

  orgId = "kuiprde";
  orgName = "kuipr.de";
  orgSubnet = "100.90.128.0/20";
  orgUtilitySubnet = "100.96.128.0/20";
  apiUrl = "http://127.0.0.1:3000/api/v1";
  dashboardDomain = "pangolin.ext.${baseDomain}";
  oidcIssuer = "https://id.ext.${baseDomain}";
  tolerance = 5 * 60;
  # niceId is also the newt --id; secretEnv names the variable in secrets/eclair/pangolin-apply.env.
  sites = {
    eclair = {
      niceId = "eclair";
      secretEnv = "NEWT_SECRET_ECLAIR";
    };
    sorbet = {
      niceId = "sorbet";
      secretEnv = "NEWT_SECRET_SORBET";
    };
  };
}
