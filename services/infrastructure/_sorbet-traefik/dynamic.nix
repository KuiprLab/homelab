{
  lib,
  constants,
  extVhosts,
  proxyHosts,
}:
# Backends that cannot be routed by label: the Docker provider only knows
# container addresses, and these are a native service and two host-networked
# containers, all listening on the podman bridge gateway.
let
  # The plugin resolves ${file:...} at runtime; split so it is not parsed as a Nix
  # URI interpolation (statix rejects the single-token form).
  clientSecretFile = "$" + "{file:/run/secrets/oidc-client-secret}";
  # The plugin requires exactly 32 characters; generated once into the data volume
  # so sessions survive restarts.
  sessionSecretFile = "$" + "{file:/data/oidc-session-secret}";

  # Host-networked backends point at loopback in their vhost; pinned proxy
  # addresses save a DNS round trip for the rest.
  backendHost = vh:
    if vh.hostname == "127.0.0.1"
    then constants.proxyGateway
    else if proxyHosts ? ${vh.hostname}
    then proxyHosts.${vh.hostname}.ip
    else vh.hostname;

  # The public vhosts, served here as well so LAN clients need no hairpin. These
  # carry no login gate: pangolin's auth and rules only apply to its own edge.
  extRouters =
    lib.mapAttrs (name: vh: {
      rule = "Host(`${vh.subdomain}`)";
      entryPoints = ["websecure"];
      service = name;
      middlewares = ["sec-headers@file"];
      tls.certResolver = "letsencrypt";
    })
    extVhosts;

  extServices = lib.mapAttrs (_: vh:
    {
      loadBalancer.servers = [
        {url = "${vh.protocol}://${backendHost vh}:${toString vh.port}";}
      ];
    }
    // lib.optionalAttrs (vh.serversTransport != null) {
      loadBalancer.serversTransport = vh.serversTransport;
    })
  extVhosts;
in {
  http = {
    serversTransports.unifi-insecure.insecureSkipVerify = true;

    middlewares = {
      sec-headers.headers = {
        stsSeconds = 31536000;
        stsIncludeSubdomains = true;
        contentTypeNosniff = true;
        referrerPolicy = "strict-origin-when-cross-origin";
        customFrameOptionsValue = "DENY";
      };

      # One session cookie for the whole zone, so a login on one app covers the
      # others. The plugin resolves ${file:...} at runtime, which keeps the client
      # secret out of the store; the same value signs the session cookie.
      oidc-auth.plugin.traefik-oidc-auth = {
        Secret = sessionSecretFile;
        Provider = {
          Url = "https://${constants.idDomain}";
          ClientId = "sorbet-forward-auth";
          ClientSecret = clientSecretFile;
          # The Pocket ID client has PKCE enabled; the plugin opts in explicitly.
          UsePkce = "true";
        };
        Scopes = ["openid" "profile" "email" "groups"];
        SessionCookie.Domain = constants.intDomain;
      };
    };

    routers =
      {
        technitium = {
          rule = "Host(`technitium.int.kuipr.de`)";
          entryPoints = ["websecure"];
          service = "technitium";
          middlewares = ["sec-headers@file"];
          tls.certResolver = "letsencrypt";
        };
        homeassistant = {
          rule = "Host(`has.int.kuipr.de`)";
          entryPoints = ["websecure"];
          service = "homeassistant";
          middlewares = ["sec-headers@file"];
          tls.certResolver = "letsencrypt";
        };
        upsnap = {
          rule = "Host(`up.int.kuipr.de`)";
          entryPoints = ["websecure"];
          service = "upsnap";
          middlewares = ["sec-headers@file"];
          tls.certResolver = "letsencrypt";
        };
      }
      // extRouters;

    services =
      {
        technitium.loadBalancer.servers = [{url = "http://${constants.proxyGateway}:5380";}];
        homeassistant.loadBalancer.servers = [{url = "http://${constants.proxyGateway}:8123";}];
        upsnap.loadBalancer.servers = [{url = "http://${constants.proxyGateway}:8090";}];
      }
      // extServices;
  };
}
