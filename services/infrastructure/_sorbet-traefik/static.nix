{
  entryPoints = {
    web = {
      address = ":80";
      http.redirections.entryPoint = {
        to = "websecure";
        scheme = "https";
      };
    };
    websecure = {
      address = ":443";
      # One wildcard certificate for the zone through DNS-01, issued once instead
      # of one per host; routers only need their certResolver.
      http.tls = {
        certResolver = "letsencrypt";
        domains = [
          {
            main = "int.kuipr.de";
            sans = ["*.int.kuipr.de"];
          }
        ];
      };
    };
  };

  # DNS-01 so the wildcard cert needs no inbound reachability; the key is passed
  # as BUNNY_API_KEY through the sops env file.
  certificatesResolvers.letsencrypt.acme = {
    email = "62436912+frostplexx@users.noreply.github.com";
    storage = "/data/acme.json";
    dnsChallenge = {
      provider = "bunny";
      # Technitium serves int.kuipr.de authoritatively inside the LAN, so lego's
      # propagation check through the container resolver can never see the TXT
      # record bunny just published.
      resolvers = ["1.1.1.1:53" "9.9.9.9:53"];
    };
  };

  providers = {
    # Same podman socket the containers are managed with.
    docker = {
      endpoint = "unix:///var/run/docker.sock";
      exposedByDefault = false;
      network = "proxy";
      watch = true;
    };
    file = {
      directory = "/etc/traefik/dynamic";
      watch = true;
    };
  };

  # Fetched at start and cached in the plugins volume.
  experimental.plugins.traefik-oidc-auth = {
    moduleName = "github.com/sevensolutions/traefik-oidc-auth";
    version = "v0.23.0";
  };

  # Query strings carry admin tokens; journald must not keep them.
  accessLog.fields.names.request_Query = "drop";
  log.level = "INFO";
}
