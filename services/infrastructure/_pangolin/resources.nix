{
  lib,
  vhosts,
  hostRoutes,
  exitNodes,
  geoAllow,
  asnDeny,
  sites,
  tolerance,
}: let
  forSite = site: lib.filterAttrs (_nick: v: v.site == site) vhosts;

  # Every newt applies only its own blueprint, so each file carries one site entry.
  siteSettings = site: {
    "${sites.${site}.niceId}" = {
      name = sites.${site}.niceId;
      "docker-socket-enabled" = true;
    };
  };

  # Priorities must be unique; 1000 leaves room for hand-written rules.
  geoRules =
    lib.imap0 (i: cc: {
      action = "pass";
      match = "country";
      value = cc;
      priority = i + 1;
    })
    geoAllow
    ++ lib.optional (geoAllow != []) {
      action = "deny";
      match = "country";
      value = "ALL";
      priority = 1000;
    };

  # One rule per ASN: the engine matches a single value, there is no wildcard.
  asnRules =
    lib.imap0 (i: asn: {
      action = "deny";
      match = "asn";
      value = "AS${toString asn}";
      priority = 500 + i;
    })
    asnDeny;

  labelsFor = edge: site: ["edge:${edge}" "site:${site}"];

  unhealthyThreshold = interval: 1 + builtins.div (tolerance + interval - 1) interval;

  # Probes hit the vhost domain over TLS, so DNS, caddy, the certificate and
  # the backend are all in the path. The name is both the reconcile key and
  # what alerts show, hence the uniqueness guard below.
  standaloneHealthChecks = let
    checks =
      lib.mapAttrsToList (_: vh: {
        inherit (vh) name;
        siteNiceId = vh.site;
        hcHostname = vh.subdomain;
        hcPort = 443;
        hcScheme = "https";
        hcPath = vh.healthcheck.path;
        hcInterval = vh.healthcheck.interval;
        hcUnhealthyInterval = vh.healthcheck."unhealthy-interval";
        hcUnhealthyThreshold = unhealthyThreshold vh.healthcheck."unhealthy-interval";
      })
      (lib.filterAttrs (_: vh: vh.private && vh.site == "sorbet" && vh.healthcheck.enable && !(vh.extra ? mode)) vhosts);
    names = map (c: c.name) checks;
    dupes = lib.filter (n: lib.count (x: x == n) names > 1) (lib.unique names);
  in
    if dupes != []
    then throw "pangolin: private vhost names key the health checks, make them unique: ${lib.concatStringsSep ", " dupes}"
    else checks;

  healthcheckFor = {
    hostname,
    port,
    protocol,
    hc,
  }: {
    enabled = hc.enable;
    inherit hostname;
    inherit port;
    scheme = protocol;
    inherit (hc) path;
    mode = "http";
    method = "GET";
    inherit (hc) interval;
    "unhealthy-interval" = hc."unhealthy-interval";
    "unhealthy-threshold" = unhealthyThreshold hc."unhealthy-interval";
    "follow-redirects" = true;
  };

  hostResourcesFor = site:
    lib.mapAttrs (_nick: r:
      {
        inherit (r) name;
        mode = "host";
        inherit (r) destination;
        "tcp-ports" = r.tcpPorts;
        "udp-ports" = r.udpPorts;
        "disable-icmp" = !r.icmp;
        labels = labelsFor "int" r.site;
      }
      // lib.optionalAttrs (r.alias != null) {inherit (r) alias;}
      // r.extra)
    (lib.filterAttrs (_: r: r.site == site) hostRoutes);

  # Plain private vhosts are served by caddy on sorbet; only explicit modes are real client-resources.
  clientResources = site:
    lib.mapAttrs (_nick: vh:
      lib.recursiveUpdate
      {
        inherit (vh) name;
        mode = "http";
        destination = vh.hostname;
        "destination-port" = vh.port;
        scheme = vh.protocol;
        "full-domain" = vh.subdomain;
        labels = labelsFor "int" vh.site;
      }
      vh.extra)
    (lib.filterAttrs (_: vh: vh.private && vh.extra ? mode) (forSite site))
    // hostResourcesFor site;

  # One public resource per vhost, shared by blueprint and container labels.
  publicResource = vh:
    lib.recursiveUpdate
    ({
        inherit (vh) name;
        mode = "http";
        "full-domain" = vh.subdomain;
        labels = labelsFor "public" vh.site;
        targets = [
          ({
              inherit (vh) hostname;
              inherit (vh) port;
              healthcheck = healthcheckFor {
                inherit (vh) hostname;
                inherit (vh) port;
                inherit (vh) protocol;
                hc = vh.healthcheck;
              };
            }
            // lib.optionalAttrs (vh.protocol != null) {
              method = vh.protocol;
            })
        ];
      }
      // lib.optionalAttrs (asnRules != [] || geoRules != []) {
        rules = asnRules ++ geoRules;
      })
    vh.extra;

  publicResourcesFor = site: lib.filterAttrs (_: vh: !vh.private) (forSite site);

  labelValue = value:
    if lib.isBool value
    then lib.boolToString value
    else if lib.isInt value
    then toString value
    else value;

  # Container labels carry the blueprint schema in dot notation: attrs become
  # a.b and list items a[0].
  flattenLabels = prefix: value:
    if lib.isAttrs value
    then lib.concatMapAttrs (key: sub: flattenLabels "${prefix}.${key}" sub) value
    else if lib.isList value
    then
      lib.foldl' (labels: entry: labels // flattenLabels "${prefix}[${toString entry.index}]" entry.value) {}
      (lib.imap0 (index: value: {inherit index value;}) value)
    else {${prefix} = labelValue value;};

  # Pangolin applies these itself: newt reads the socket and pushes the labels
  # on every container event, so the site blueprint must not repeat them.
  dockerLabelsFor = site:
    lib.concatMapAttrs (name: vh: let
      containerHost =
        if vh.containerHost != null
        then vh.containerHost
        else vh.hostname;
    in {
      ${containerHost}.labels = flattenLabels "pangolin.proxy-resources.${name}" (publicResource vh);
    })
    (publicResourcesFor site);

  exitNodeResources = site:
    lib.mapAttrs (_nick: en:
      {
        inherit (en) name;
        mode = "exit-node";
        sites = [site];
        inherit (en) users;
        roles = en.roles or [];
        labels = labelsFor "exit" site;
      }
      // (en.extra or {}))
    (lib.filterAttrs (_: en: en.site == site) exitNodes);
in {
  inherit
    siteSettings
    clientResources
    exitNodeResources
    dockerLabelsFor
    standaloneHealthChecks
    ;
}
