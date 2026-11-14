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

  # Country allow-list enforced on every public resource.
  geoAllowCountries = [
    "AT"
    "BE"
    "BG"
    "HR"
    "CY"
    "CZ"
    "DK"
    "EE"
    "FI"
    "FR"
    "DE"
    "GR"
    "HU"
    "IE"
    "IT"
    "LV"
    "LT"
    "LU"
    "MT"
    "NL"
    "PL"
    "PT"
    "RO"
    "SK"
    "SI"
    "ES"
    "SE"
  ];

  # ASN deny-list: hosting, cloud and VPN providers are never residential clients.
  asnDenyList = [
    9009 # M247 Europe — VPN/anti-detect hosting
    60068 # Datacamp (CDN77)
    136787 # PacketHub (NordVPN)
    212238 # Datacamp (NordVPN/ExpressVPN ranges)
    62240 # Clouvider — VPN-friendly hosting
    210644 # AEZA — bulletproof hosting
    197068 # HLL (Qrator) — abuse host
    14061 # DigitalOcean
    63949 # Akamai (Linode)
    20473 # The Constant Company (Vultr)
    51167 # Contabo
    12876 # Scaleway
    16276 # OVH
    24940 # Hetzner
  ];

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
