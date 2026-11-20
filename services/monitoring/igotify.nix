{config, ...}: let
  constants = config.flake.constants;
  healthFlags = config.flake.healthFlags;
  proxyIp = "10.89.0.61";
  vhost = config.flake.pangolinVirtualHosts."igotify";
  labels =
    config.flake.pangolinRuleLabels "igotify"
    // config.flake.pangolinHealthcheckLabels "igotify" vhost
    // config.flake.pangolinPublicLabels "igotify" vhost;
in {
  flake = {
    podmanProxyHosts.igotify.ip = proxyIp;

    pangolinVirtualHosts."igotify" = {
      site = "sorbet";
      name = "iGotify";
      subdomain = "igotify.ext.kuipr.de";
      private = false;
      hostname = "igotify";
      port = 8080;
      healthcheck.path = "/Version";
    };

    nixosModules.igotify = {lib, ...}: {
      systemd.tmpfiles.rules = [
        "d /var/lib/igotify 0750 root root - -"
      ];

      virtualisation.oci-containers.containers.igotify = {
        inherit labels;
        image = "ghcr.io/androidseb25/igotify-notification-assist:v1.6.1.0@sha256:cb1432ab8963d08177936463ecf3b6dc227c2992f4574befb79e98c643f048e6";
        volumes = [
          "/var/lib/igotify:/app/data"
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
        extraOptions =
          [
            "--dns=${constants.lanIp}"
            "--network=proxy:ip=${proxyIp}"
          ]
          ++ healthFlags {
            cmd = "curl -fsS http://127.0.0.1:8080/Version";
            startPeriod = "30s";
            timeout = "5s";
          };
      };

      systemd.services."podman-igotify" = {
        after = ["podman-gotify.service"];
        wants = ["podman-gotify.service"];
        serviceConfig.Restart = lib.mkOverride 90 "always";
      };
    };
  };
}
