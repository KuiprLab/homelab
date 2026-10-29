# Gotify — self-hosted alert delivery, public via Pangolin.
#
# The container listens on loopback only; Pangolin's public proxy-resource
# routes gotify.ext.kuipr.de to 127.0.0.1:8085. Authentication is native
# Gotify OIDC against Authelia (client `gotify` in
# secrets/sorbet/authelia/configuration.yml), so the web UI has no second
# password prompt.
#
# Alert sources authenticate with an application token. A reconciler
# (gotify-provision.service) creates the applications and writes their tokens
# to /var/lib/gotify-provision. Tokens never enter git. The reconciler needs
# HTTP Basic auth, so GOTIFY_LOCALAUTH_ENABLED is true; the web UI still uses
# OIDC because GOTIFY_OIDC_AUTO_REDIRECT is set. The admin password is a
# 64-character sops secret.
#
# Dead-man switch: Gotify runs on sorbet, so it cannot report that sorbet is
# dead. Keep an out-of-band (email) integration on sorbet's healthchecks.io
# check; everything else can deliver through Gotify.
_: {
  flake = {
    pangolinVirtualHosts."gotify" = {
      site = "sorbet";
      name = "Gotify";
      subdomain = "gotify.ext.kuipr.de";
      private = false;
      port = 8085;
      healthcheck.path = "/health";
    };

    nixosModules.gotify = {
      config,
      lib,
      ...
    }: {
      sops.secrets = {
        # Shared with the reconciler on both hosts. Eclair needs only the
        # admin password for provisioning, not the OIDC client secret.
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
        image = "docker.io/gotify/server:3.1.1@sha256:44fc5bbd1c0618878e33073d38c2c13126b48f245c3fe12236b1da48eb203b86";
        volumes = [
          "/var/lib/gotify:/app/data"
        ];
        ports = [
          "127.0.0.1:8085:80"
        ];
        environment = {
          GOTIFY_SERVER_PORT = "80";
          # Pangolin terminates TLS in front of the container. Mark the
          # session cookie Secure even though the newt hop is plain HTTP.
          GOTIFY_SERVER_SECURECOOKIE = "true";
          GOTIFY_DATABASE_DIALECT = "sqlite3";
          GOTIFY_DATABASE_CONNECTION = "/app/data/gotify.db";
          GOTIFY_UPLOADEDIMAGESDIR = "/app/data/images/";
          GOTIFY_PLUGINSDIR = "/app/data/plugins/";
          # SSO for the UI. Local auth stays enabled only so the reconciler
          # can use HTTP Basic auth; the UI auto-redirects to Authelia.
          GOTIFY_LOCALAUTH_ENABLED = "true";
          GOTIFY_OIDC_ENABLED = "true";
          GOTIFY_OIDC_ISSUER = "https://auth.ext.kuipr.de";
          GOTIFY_OIDC_CLIENTID = "gotify";
          GOTIFY_OIDC_REDIRECTURL = "https://gotify.ext.kuipr.de/auth/oidc/callback";
          GOTIFY_OIDC_AUTOREGISTER = "true";
          # The reconciler creates a local user named after the Authelia user
          # (daniel). Linking by username makes the OIDC identity use that
          # same user, so applications and the iOS client token share an owner.
          GOTIFY_OIDC_LINK_BY_USERNAME = "true";
          GOTIFY_OIDC_USERNAMECLAIM = "preferred_username";
          GOTIFY_OIDC_GROUPS_CLAIM = "groups";
          GOTIFY_OIDC_GROUPS_ADMIN = "admin";
          GOTIFY_OIDC_SCOPES = "openid,profile,email,groups";
          GOTIFY_OIDC_AUTO_REDIRECT = "true";
          # Empty prompt reuses the Authelia session; no forced re-login.
          GOTIFY_OIDC_PROMPT = "";
        };
        environmentFiles = [
          config.sops.secrets."gotify/admin".path
          config.sops.secrets."gotify/oidc".path
        ];
        log-driver = "journald";
        extraOptions = [
          # Use the LAN resolver on this host instead of aardvark-dns (same
          # reason as the other containers): public names resolve through it.
          "--dns=192.168.0.85"
          # Podman does not inherit the image HEALTHCHECK; mirror it.
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
