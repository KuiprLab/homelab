# Backends that cannot be routed by label: the Docker provider only knows
# container addresses, and these are a native service and two host-networked
# containers, all listening on the podman bridge gateway.
{
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

      forward-auth.forwardAuth = {
        address = "http://sorbet-forward-auth:4181/portals/main";
        authResponseHeaders = [
          "X-Forwarded-User"
          "X-Forwarded-Displayname"
          "X-Authenticated-User"
        ];
        trustForwardHeader = true;
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
