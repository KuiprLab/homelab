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
          exposedAddress: "https://${nbDomain}:443"
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
      # Declarative control-plane state (GitOps): groups, the home-LAN
      # route, and the int.kuipr.de DNS zone are converged by
      # netbird-apply from the Management REST API. One-time imperative
      # bits stay manual: admin account (dashboard) and the PAT
      # (NB_PAT in sops, created in dashboard → Access Tokens).
      applyScript = pkgs.writeShellScript "netbird-apply" ''
        set -euo pipefail
        . "$NB_ENV_FILE"
        API="https://${nbDomain}/api"
        req() { curl -sSf -H "Authorization: Token $NB_PAT" -H "Content-Type: application/json" "$@"; }
        block() { set +e; out=$(req "$@" 2>&1); rc=$?; set -e; echo "$out"; return $rc; }

        gid() { req "$API/groups" | jq -r --arg n "$1" 'first(.[]|select(.name==$n)|.id) // empty'; }

        # --- groups (create-if-missing; membership is setup-key driven) ---
        for g in servers clients router; do
          [ -n "$(gid "$g")" ] || req -X POST -d "{\"name\":\"$g\",\"peers\":[]}" "$API/groups"
        done

        cid=$(gid clients)
        rgid=$(gid router)

        # --- legacy API route home-lan (192.168.0.0/24 via router group) ---
        # NOTE: route.`groups` are DISTRIBUTION groups (who gets the route);
        # route.`peer_groups` name the routing peer (sorbet). The v2
        # /api/networks objects do not distribute without a destination-
        # resource policy, so we use the legacy route API instead.
        route_body="{\"network_id\":\"home-lan\",\"network\":\"192.168.0.0/24\",\"description\":\"declarative home LAN route\",\"groups\":[\"$cid\"],\"peer_groups\":[\"$rgid\"],\"masquerade\":true,\"metric\":9999,\"enabled\":true}"
        rid=$(req "$API/routes" | jq -r 'first(.[]|select(.network_id=="home-lan")|.id) // empty')
        if [ -n "$rid" ]; then
          req -X PUT -d "$route_body" "$API/routes/$rid"
        else
          req -X POST -d "$route_body" "$API/routes"
        fi

        # --- nameserver group int-domains -> sorbet/pihole ---
        ns_body="{\"name\":\"int-domains\",\"description\":\"*.int.kuipr.de -> sorbet\",\"nameservers\":[{\"ip\":\"192.168.0.85\",\"ns_type\":\"udp\",\"port\":53}],\"enabled\":true,\"groups\":[\"$cid\"],\"primary\":false,\"domains\":[\"int.kuipr.de\"],\"search_domains_enabled\":true}"
        nsid=$(req "$API/dns/nameservers" | jq -r 'first(.[]|select(.name=="int-domains")|.id) // empty')
        if [ -n "$nsid" ]; then
          req -X PUT -d "$ns_body" "$API/dns/nameservers/$nsid"
        else
          req -X POST -d "$ns_body" "$API/dns/nameservers"
        fi

        # --- router group membership pinned to sorbet ---
        sorbet=$(req "$API/peers" | jq -r 'first(.[]|select(.hostname=="sorbet")|.id) // empty')
        if [ -n "$sorbet" ]; then
          cur=$(req "$API/groups/$rgid" | jq -c '(.peers // [] | map(.id // .)) | sort')
          want=$(printf '["%s"]' "$sorbet")
          if [ "$cur" != "$want" ]; then
            req -X PUT -d "{\"name\":\"router\",\"peers\":[\"$sorbet\"]}" "$API/groups/$rgid"
          fi
        fi
      '';
    in {
      systemd = {
        services.netbird-apply = {
          description = "NetBird: converge control-plane state from nix spec";
          after = ["podman-netbird-server.service" "sops-nix.service"];
          wants = ["sops-nix.service"];
          serviceConfig = {
            Type = "oneshot";
            RuntimeMaxSec = "5min";
          };
          path = with pkgs; [curl jq];
          # sops-nix secret: a set; `.path` coerces to the installed file.
          environment.NB_ENV_FILE = toString config.sops.secrets."netbird/env".path;
          script = toString applyScript;
        };

        timers.netbird-apply = {
          wantedBy = ["timers.target"];
          timerConfig = {
            OnBootSec = "2min";
            OnUnitActiveSec = "1h";
            RandomizedDelaySec = "60";
          };
        };
      };

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
          # not hardened: daemon needs root to apply resolv.conf (netbird DNS)
          hardened = false;
        };
        useRoutingFeatures = "client";
      };
    };
  };
}
