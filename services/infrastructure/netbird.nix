# NetBird control plane on eclair (replaces pangolin/gerbil/traefik).
#
# Official combined container (netbirdio/netbird-server: management +
# signal + relay + embedded IdP in one) plus the dashboard container,
# fronted by caddy (services/eclair-caddy.nix at netbird.kuipr.de), which
# owns :443. STUN answers on UDP 3478 directly — never proxied.
#
# config.yaml mirrors the official getting-started.sh (combined/external-
# proxy variant): exposedAddress https://netbird.kuipr.de, issuer
# https://netbird.kuipr.de/oauth2 (embedded IdP), sqlite store, secret
# material from sops via a rendered env file, caddy (127.0.0.1) as the
# trusted reverse proxy.
#
# First-run (imperative, once):
#   1. Deploy; open https://netbird.kuipr.de and create the admin account.
#   2. Dashboard → setup keys: create two reusable keys ("servers",
#      "devices").
#   3. `opsops edit secrets/eclair/netbird.env` → put the keys into
#      NB_SETUP_KEY_SERVERS / NB_SETUP_KEY_DEVICES; redeploy.
#   4. Dashboard/API: routing config groups/policies/routes/DNS come from
#      netbird-apply (below).
#   5. Enroll hosts: `netbird up --management-url https://netbird.kuipr.de
#      --setup-key <key>` (one-time; the daemon persists state).
_: {
  flake = {
    eclairCaddyVirtualHosts."netbird.kuipr.de" = {
      # Routing per the upstream "Combined container" template:
      # gRPC (h2c), then management/signal/relay/api/oauth2, then dashboard
      # catch-all. All upstream traffic targets the combined container; the
      # dashboard listens separately on 8080.
      extraConfig = ''
        @grpc header Content-Type application/grpc*
        reverse_proxy @grpc h2c://127.0.0.1:8081

        @backend path /relay* /ws-proxy/* /api/* /oauth2/*
        reverse_proxy @backend 127.0.0.1:8081

        reverse_proxy /* 127.0.0.1:8080
      '';
      name = "NetBird";
    };

    eclairNixosModules.netbird = {
      config,
      pkgs,
      ...
    }: let
      nbDomain = "netbird.kuipr.de";
      dashboardEnv = config.sops.templates."netbird/dashboard.env".path;
      configDir = "/var/lib/netbird/config";
      renderConfig = pkgs.writeShellScript "netbird-render-config" ''
        set -euo pipefail
        . "${config.sops.secrets."netbird/env".path}"
        install -d -m 700 /var/lib/netbird/config
        cat > /var/lib/netbird/config/config.yaml <<EOF
        server:
          listenAddress: ":80"
          exposedAddress: "https://${nbDomain}"
          stunPorts:
            - 3478
          metricsPort: 9090
          healthcheckAddress: ":9000"
          logLevel: "info"
          logFile: "console"
          authSecret: "''${NB_RELAY_AUTH_SECRET}"
          dataDir: "/var/lib/netbird"
          auth:
            issuer: "https://${nbDomain}/oauth2"
            signKeyRefreshEnabled: true
            sessionCookieEncryptionKey: "''${NB_SESSION_KEY}"
            dashboardRedirectURIs:
              - "https://${nbDomain}/nb-auth"
              - "https://${nbDomain}/nb-silent-auth"
            cliRedirectURIs:
              - "http://localhost:53000/"
          reverseProxy:
            trustedHTTPProxies:
              - "127.0.0.1/32"
          store:
            engine: "sqlite"
            encryptionKey: "''${NB_DATASTORE_KEY}"
        EOF
      '';
    in {
      sops.secrets."netbird/env" = {
        sopsFile = ../../secrets/eclair/netbird.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };
      sops.templates."netbird/dashboard.env" = {
        content = ''
          NETBIRD_MGMT_API_ENDPOINT=https://${nbDomain}
          NETBIRD_MGMT_GRPC_API_ENDPOINT=https://${nbDomain}
          AUTH_AUDIENCE=netbird-dashboard
          AUTH_CLIENT_ID=netbird-dashboard
          AUTH_CLIENT_SECRET=
          AUTH_AUTHORITY=https://${nbDomain}/oauth2
          USE_AUTH0=false
          AUTH_SUPPORTED_SCOPES=openid profile email groups
          AUTH_REDIRECT_URI=/nb-auth
          AUTH_SILENT_REDIRECT_URI=/nb-silent-auth
          NGINX_SSL_PORT=443
          LETSENCRYPT_DOMAIN=none
        '';
        owner = "root";
      };

      virtualisation.oci-containers = {
        backend = "podman";
        containers = {
          "netbird-dashboard" = {
            image = "docker.io/netbirdio/dashboard:latest";
            autoStart = true;
            environmentFiles = [dashboardEnv];
            ports = ["127.0.0.1:8080:80/tcp"];
          };
          "netbird-server" = {
            image = "docker.io/netbirdio/netbird-server:latest";
            autoStart = true;
            ports = [
              "127.0.0.1:8081:80/tcp"
              # STUN: direct UDP, never through the reverse proxy.
              "3478:3478/udp"
            ];
            volumes = [
              "netbird_server:/var/lib/netbird:rw"
              "${configDir}/config.yaml:/etc/netbird/config.yaml:ro"
            ];
            dependsOn = ["netbird-dashboard"];
          };
        };
      };

      # Render config.yaml from the sops env file before the container
      # starts (the container mounts it read-only).
      systemd.services."podman-netbird-server".preStart = toString renderConfig;
      systemd.services."podman-netbird-server".serviceConfig.EnvironmentFile =
        config.sops.secrets."netbird/env".path;

      networking.firewall.allowedUDPPorts = [3478];

      # eclair is also a NetBird peer: its caddy reaches authelia/navidrome
      # on sorbet over the overlay, and (optionally) the admin CLI.
      services.netbird = {
        clients.default = {
          interface = "wt0";
          port = 51820;
        };
        useRoutingFeatures = "client";
      };
    };
  };
}
