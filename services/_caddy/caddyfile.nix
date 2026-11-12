{
  lib,
  vhosts,
}: let
  byCaddy = lib.filterAttrs (_: v: v.private && v.site == "sorbet" && !(v.extra ? mode)) vhosts;

  stray = lib.filterAttrs (_: v: v.private && v.site != "sorbet" && !(v.extra ? mode)) vhosts;

  authVhosts = lib.filterAttrs (_: v: v.auth.enable) byCaddy;

  # Container upstreams win over static ones; technitium is a systemd service.
  # containerHost is explicit because reading the containers option would recurse
  # through the labels this module attaches.
  usesDocker = v: v.containerHost != null;

  dockerVhosts = lib.filter usesDocker (lib.attrValues byCaddy);

  # Upstreams come from the docker module: caddy dials whatever the container
  # carrying this selector label reports, so no host port is published.
  caddyLabelsFor = v: {
    "homelab.caddy.vhost" = v.subdomain;
    "com.caddyserver.http.enable" = "true";
    "com.caddyserver.http.upstream.port" = toString v.port;
  };

  reverseProxyFor = v:
    "reverse_proxy {\n"
    + "  dynamic docker {\n"
    + "    label homelab.caddy.vhost ${v.subdomain}\n"
    + "  }\n"
    + lib.optionalString (v.protocol == "https") (
      "  transport http {\n    tls"
      + lib.optionalString v.tlsInsecureSkipVerify "\n    tls_insecure_skip_verify"
      + "\n  }\n"
    )
    + "}";

  staticReverseProxyFor = v:
    ''reverse_proxy ${v.protocol}://${v.hostname}:${toString v.port}''
    + lib.optionalString v.tlsInsecureSkipVerify " {\n      transport http {\n        tls_insecure_skip_verify\n      }\n    }";

  proxyFor = v:
    if usesDocker v
    then reverseProxyFor v
    else staticReverseProxyFor v;

  indentBy = spaces: lib.replaceStrings ["\n"] ["\n${spaces}"];

  # Bypass paths still reach the backend: the pangolin health check uses one and
  # must not be answered with a redirect to the login.
  siteRoutesFor = v: let
    proxied = indentBy "  " (proxyFor v);
    bypass =
      lib.concatMapStringsSep "\n" (p: ''
        route ${p} {
          ${proxied}
        }
      '')
      v.auth.bypassPaths;
  in
    if !v.auth.enable
    then proxyFor v
    else ''
      @login path /caddy-security/*
      route @login {
        authenticate with pocketid_portal
      }
      ${bypass}
      route {
        authorize with pocketid_policy
        ${proxied}
      }
    '';

  pocketIdUrl = "https://id.ext.kuipr.de";
  oidcClientId = "caddy-security";

  # Authcrunch matches the redirect URL host verbatim, port included, so the
  # :443 form has to be listed as well: pangolin forwards the Host header with it.
  trustLoginRedirects = lib.concatMapStringsSep "\n        " (v:
    "trust login redirect uri domain exact ${v.subdomain} path prefix /\n        "
    + "trust login redirect uri domain exact ${v.subdomain}:443 path prefix /")
  (lib.attrValues authVhosts);

  loginConfig = ''
    order authenticate before respond
    security {
      oauth identity provider pocketid {
        realm pocketid
        driver generic
        client_id ${oidcClientId}
        client_secret {env.POCKETID_OIDC_CLIENT_SECRET}
        scopes openid email profile
        base_auth_url ${pocketIdUrl}
        metadata_url ${pocketIdUrl}/.well-known/openid-configuration
      }

      authentication portal pocketid_portal {
        crypto default token lifetime 3600
        crypto key sign-verify {env.CADDY_SECURITY_JWT_KEY}
        enable identity provider pocketid
        ${trustLoginRedirects}
        transform user {
          match realm pocketid
          action add role authp/user
        }
      }

      authorization policy pocketid_policy {
        set auth url /caddy-security/oauth2/pocketid
        crypto key verify {env.CADDY_SECURITY_JWT_KEY}
        allow roles authp/user
      }
    }
  '';
in {
  inherit
    byCaddy
    stray
    authVhosts
    dockerVhosts
    caddyLabelsFor
    siteRoutesFor
    loginConfig
    ;
}
