# No Authelia in front: the iOS app cannot complete a browser SSO flow.
_: {
  flake = {
    pangolinVirtualHosts."igotify" = {
      site = "sorbet";
      name = "iGotify";
      subdomain = "igotify.ext.kuipr.de";
      private = false;
      port = 8681;
      healthcheck.path = "/Version";
    };

    nixosModules.igotify = {lib, ...}: {
      systemd.tmpfiles.rules = [
        "d /var/lib/igotify 0750 root root - -"
      ];

      virtualisation.oci-containers.containers.igotify = {
        image = "ghcr.io/androidseb25/igotify-notification-assist:v1.6.0.1@sha256:69fc3469e8461284f5b7794bad3466cead0030cc7e2e182239125360a6befd9d";
        volumes = [
          "/var/lib/igotify:/app/data"
        ];
        ports = [
          "127.0.0.1:8681:8080"
        ];
        environment = {
          ENABLE_CONSOLE_LOG = "true";
          ENABLE_USER_UI = "true";
          ENABLE_SCALAR_UI = "false";
          GOTIFY_URLS = "";
          GOTIFY_CLIENT_TOKENS = "";
          SECNTFY_TOKENS = "";
        };
        log-driver = "journald";
        extraOptions = [
          "--dns=192.168.0.85"
          "--health-cmd=curl -fsS http://127.0.0.1:8080/Version"
          "--health-interval=30s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=30s"
          "--health-timeout=5s"
        ];
      };

      systemd.services."podman-igotify" = {
        after = ["podman-gotify.service"];
        wants = ["podman-gotify.service"];
        serviceConfig.Restart = lib.mkOverride 90 "always";
      };
    };
  };
}
