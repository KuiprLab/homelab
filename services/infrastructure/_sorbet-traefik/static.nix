{
  entryPoints = {
    web = {
      address = ":80";
      http.redirections.entryPoint = {
        to = "websecure";
        scheme = "https";
      };
    };
    websecure.address = ":443";
  };

  # DNS-01 so the wildcard cert needs no inbound reachability; the key is passed
  # as BUNNY_API_KEY through the sops env file.
  certificatesResolvers.letsencrypt.acme = {
    email = "62436912+frostplexx@users.noreply.github.com";
    storage = "/data/acme.json";
    dnsChallenge.provider = "bunny";
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

  # Query strings carry admin tokens; journald must not keep them.
  accessLog.fields.names.request_Query = "drop";
  log.level = "INFO";
}
