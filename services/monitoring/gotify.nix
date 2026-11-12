{config, ...}: let
  proxyIp = "10.89.0.60";
  vhost = config.flake.pangolinVirtualHosts."gotify";
  labels =
    config.flake.pangolinRuleLabels "gotify"
    // config.flake.pangolinHealthcheckLabels "gotify" vhost
    // {
      "pangolin.proxy-resources.gotify.name" = vhost.name;
      "pangolin.proxy-resources.gotify.full-domain" = vhost.subdomain;
      "pangolin.proxy-resources.gotify.mode" = "http";
      "pangolin.proxy-resources.gotify.labels[0]" = "edge:public";
      "pangolin.proxy-resources.gotify.labels[1]" = "site:${vhost.site}";
      "pangolin.proxy-resources.gotify.targets[0].hostname" = vhost.hostname;
      "pangolin.proxy-resources.gotify.targets[0].port" = toString vhost.port;
      "pangolin.proxy-resources.gotify.targets[0].method" = vhost.protocol;
    };
in {
  flake = {
    podmanProxyHosts.gotify.ip = proxyIp;

    pangolinVirtualHosts."gotify" = {
      site = "sorbet";
      name = "Gotify";
      subdomain = "gotify.ext.kuipr.de";
      private = false;
      hostname = "gotify";
      port = 80;
      healthcheck.path = "/health";
    };

    nixosModules.gotify = {
      config,
      lib,
      ...
    }: {
      sops.secrets = {
        # Shared with the reconciler on both hosts; eclair needs only the admin password.
        "gotify/admin" = {
          sopsFile = ../../secrets/shared/gotify-admin.env;
          format = "dotenv";
          key = "";
          owner = "root";
          restartUnits = ["podman-gotify.service"];
        };

        "gotify/oidc" = {
          sopsFile = ../../secrets/sorbet/gotify-oidc.env;
          format = "dotenv";
          key = "";
          owner = "root";
          restartUnits = ["podman-gotify.service"];
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/gotify 0750 root root - -"
      ];

      virtualisation.oci-containers.containers.gotify = {
        inherit labels;
        image = "docker.io/gotify/server:3.1.1@sha256:44fc5bbd1c0618878e33073d38c2c13126b48f245c3fe12236b1da48eb203b86";
        volumes = [
          "/var/lib/gotify:/app/data"
        ];
        environment = {
          GOTIFY_SERVER_PORT = "80";
          GOTIFY_SERVER_SECURECOOKIE = "true";
          GOTIFY_DATABASE_DIALECT = "sqlite3";
          GOTIFY_DATABASE_CONNECTION = "/app/data/gotify.db";
          GOTIFY_UPLOADEDIMAGESDIR = "/app/data/images/";
          GOTIFY_PLUGINSDIR = "/app/data/plugins/";
          # Local auth only because the reconciler uses HTTP Basic auth.
          GOTIFY_LOCALAUTH_ENABLED = "true";
          GOTIFY_OIDC_ENABLED = "true";
          GOTIFY_OIDC_ISSUER = "https://id.ext.kuipr.de";
          GOTIFY_OIDC_CLIENTID = "gotify";
          GOTIFY_OIDC_REDIRECTURL = "https://gotify.ext.kuipr.de/auth/oidc/callback";
          GOTIFY_OIDC_AUTOREGISTER = "true";
          GOTIFY_OIDC_LINK_BY_USERNAME = "true";
          GOTIFY_OIDC_USERNAMECLAIM = "preferred_username";
          GOTIFY_OIDC_GROUPS_CLAIM = "groups";
          GOTIFY_OIDC_GROUPS_ADMIN = "admin";
          GOTIFY_OIDC_SCOPES = "openid,profile,email,groups";
          GOTIFY_OIDC_AUTO_REDIRECT = "true";
          GOTIFY_OIDC_PROMPT = "";
        };
        environmentFiles = [
          config.sops.secrets."gotify/admin".path
          config.sops.secrets."gotify/oidc".path
        ];
        log-driver = "journald";
        extraOptions = [
          "--dns=192.168.0.85"
          "--network=proxy:ip=${proxyIp}"
          "--health-cmd=curl -fsS http://127.0.0.1:80/health"
          "--health-interval=30s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=30s"
          "--health-timeout=5s"
        ];
      };

      systemd.services."podman-gotify".serviceConfig.Restart = lib.mkOverride 90 "always";
    };
  };
}
