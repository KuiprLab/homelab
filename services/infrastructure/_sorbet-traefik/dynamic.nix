# Backends that cannot be routed by label: the Docker provider only knows
# container addresses, and these are a native service and two host-networked
# containers, all listening on the podman bridge gateway.
let
  # The plugin resolves ${file:...} at runtime; split so it is not parsed as a Nix
  # URI interpolation (statix rejects the single-token form).
  clientSecretFile = "$" + "{file:/run/secrets/oidc-client-secret}";
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
        Secret = clientSecretFile;
        Provider = {
          Url = "https://id.ext.kuipr.de";
          ClientId = "sorbet-forward-auth";
          ClientSecret = clientSecretFile;
          # The Pocket ID client has PKCE enabled; the plugin opts in explicitly.
          UsePkce = "true";
        };
        Scopes = ["openid" "profile" "email" "groups"];
        SessionCookie.Domain = "int.kuipr.de";
      };
    };

    routers = {
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
    };

    services = {
      technitium.loadBalancer.servers = [{url = "http://10.89.0.1:5380";}];
      homeassistant.loadBalancer.servers = [{url = "http://10.89.0.1:8123";}];
      upsnap.loadBalancer.servers = [{url = "http://10.89.0.1:8090";}];
    };
  };
}
