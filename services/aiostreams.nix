# AIOStreams — Stremio super-addon (https://github.com/Viren070/AIOStreams).
# VPN-routed via gluetun: the container joins gluetun's network namespace, so
# port 3000 is published by the gluetun container (see gluetun.nix) and caddy
# proxies it as aiostreams.ext.kuipr.de.
#
# The vhost is deliberately *not* behind authelia: Stremio (and the Jellyfin
# apps) fetch manifests and streams without a browser session, so forward auth
# would break every client. AIOStreams gates itself instead — the configure
# page is protected by a per-user password, and the operator dashboard by
# AIOSTREAMS_AUTH from the sops secret.
#
# GitOps note: every startup setting lives here or in secrets/sorbet/aiostreams.env,
# as do the instance settings locked below. What is *not* tracked here is the
# per-user addon config (addons, filters, sorting, formatter): AIOStreams stores
# it encrypted per user in its SQLite db at /var/lib/aiostreams/db.sqlite, with
# no env var for it. Back the db up; it cannot be reconstructed from this repo.
_: {
  flake = {
    caddyVirtualHosts."aiostreams.ext.kuipr.de" = {
      extraConfig = ''
        reverse_proxy 127.0.0.1:3000
      '';
      name = "AIOStreams";
    };

    gatusEndpoints = [
      {
        name = "AIOStreams";
        group = "Media";
        # /api/v1/health also round-trips the SQLite db, so a 200 means the
        # addon can actually serve configs, not just that express is up.
        url = "https://aiostreams.ext.kuipr.de/api/v1/health";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
        ];
        # AIOStreams only binds the port *after* its initial anime-database
        # refresh, which takes minutes on a cold data dir — every restart would
        # otherwise trip the global failure-threshold of 2 (~2min) and page.
        alerts = [
          {
            type = "discord";
            failure-threshold = 6;
          }
        ];
      }
    ];

    nixosModules.aiostreams = {pkgs, ...}: let
      # gluetun's DNS-over-TLS resolver refuses any answer containing a private
      # address (its DNS-rebinding guard, DOT_PRIVATE_ADDRESS). Public DNS for
      # *.ext.kuipr.de returns both eclair's public IP and 192.168.0.85 for LAN
      # hairpinning, so the whole answer comes back REFUSED inside the netns and
      # OIDC discovery fails with a bare "fetch failed".
      #
      # Resolve the issuer from a hosts file instead of loosening the guard for
      # everything else sharing gluetun (slskd included). The issuer URL must
      # stay byte-identical to what the browser uses — AIOStreams checks the
      # discovered issuer against the configured one — so only the address is
      # fixed here, not the name. Caddy on 192.168.0.85 terminates TLS for this
      # vhost with a real certificate, so SNI and verification still work.
      #
      # This replaces podman's generated /etc/hosts, hence the loopback entries;
      # --add-host cannot be used because podman rejects it for a container
      # joined to another container's network namespace.
      hostsFile = pkgs.writeText "aiostreams-hosts" ''
        127.0.0.1 localhost
        ::1 localhost ip6-localhost ip6-loopback
        192.168.0.85 auth.ext.kuipr.de
      '';
    in {
      sops.secrets = {
        "aiostreams.env" = {
          sopsFile = ../secrets/sorbet/aiostreams.env;
          format = "dotenv";
          key = "";
          restartUnits = ["podman-aiostreams.service"];
        };

        # Kept separate from aiostreams.env so the OIDC client secret can be
        # rotated without touching SECRET_KEY, which must never change.
        "aiostreams-oidc.env" = {
          sopsFile = ../secrets/sorbet/aiostreams-oidc.env;
          format = "dotenv";
          key = "";
          restartUnits = ["podman-aiostreams.service"];
        };
      };

      systemd = {
        services.podman-aiostreams = {
          requires = ["podman-gluetun.service"];
          after = ["podman-gluetun.service"];
          partOf = ["podman-compose-gluetun-root.target"];
          wantedBy = ["podman-compose-gluetun-root.target"];
        };

        tmpfiles.rules = ["d /var/lib/aiostreams 0700 root root -"];
      };

      virtualisation.oci-containers.containers.aiostreams = {
        image = "ghcr.io/viren070/aiostreams:latest";
        volumes = [
          "/var/lib/aiostreams:/app/data"
          "${hostsFile}:/etc/hosts:ro"
        ];
        environment = {
          TZ = "Europe/Berlin";
          NODE_ENV = "production";
          PORT = "3000";
          BASE_URL = "https://aiostreams.ext.kuipr.de";
          DATABASE_URI = "sqlite://./data/db.sqlite";
          LOG_LEVEL = "info";
          LOG_FORMAT = "json";

          # --- locked runtime settings ---------------------------------------
          # Everything below is a *runtime* setting: AIOStreams would normally
          # store it in its db and let the dashboard edit it live. Setting the
          # env var turns it into a locked override — the value is forced and
          # the dashboard renders the field read-only, so this file is the only
          # place it can change. Lock what is security-relevant or worth seeing
          # in a diff; leave the rest editable in the dashboard.

          # The configure page requires an operator login (AIOSTREAMS_AUTH),
          # instead of being public. The instance is reachable from the open
          # internet, so this is the difference between "only daniel can create
          # a config" and "anyone can". It also turns on the config-write gate;
          # its CONFIG_ACCESS_KEY is generated and persisted on first run and
          # deliberately left out of this file — rotating it invalidates every
          # existing config until re-saved.
          AIOSTREAMS_AUTH_REQUIRED = "true";

          # Stremio keys installed addons by this id. Changing it orphans every
          # existing install, so pin the default rather than leave a UI field
          # that can silently do that.
          ADDON_ID = "com.aiostreams.viren070";

          # SSRF guards. Health-check and sync URLs are user-supplied and
          # fetched by the server, which sits on the LAN — these two switches
          # decide whether those fetches may reach private addresses. Both
          # default to false; locking them means no dashboard toggle can
          # turn the addon into a LAN scanner.
          HEALTH_CHECK_ALLOW_PRIVATE_URLS = "false";
          SYNC_ALLOW_PRIVATE_URLS = "false";

          # Do not let configured addons scrape this same instance (loop guard).
          DISABLE_SELF_SCRAPING = "true";

          # Single-operator instance: no community sharing, and do not serve
          # /community/export.json for other instances to mirror.
          COMMUNITY_FORMATTERS = "off";
          COMMUNITY_TEMPLATES = "off";
          COMMUNITY_PUBLIC_EXPORT = "false";

          # SSO against authelia. The client is registered under
          # identity_providers.oidc.clients in secrets/sorbet/authelia/configuration.yml;
          # authelia holds a pbkdf2 digest of the secret, AIOStreams the
          # plaintext (aiostreams-oidc.env). Redirect URI is BASE_URL +
          # /api/v1/auth/oidc/callback and must match authelia exactly.
          AIOSTREAMS_OIDC_ENABLED = "true";
          AIOSTREAMS_OIDC_ISSUER = "https://auth.ext.kuipr.de";
          AIOSTREAMS_OIDC_CLIENT_ID = "aiostreams";
          # authelia only emits group membership when the scope is requested.
          AIOSTREAMS_OIDC_SCOPES = "openid profile email groups";
          # An SSO username that matches an AIOSTREAMS_AUTH user *is* that user
          # (same permissions) rather than colliding with it. Safe here because
          # authelia's backend is a file this repo controls — nobody can
          # self-service a preferred_username into impersonating daniel. Without
          # this, "daniel" over SSO is refused as oidc_username_conflict.
          AIOSTREAMS_OIDC_LINK_BY_USERNAME = "true";
          # No group mapping on purpose: an SSO identity that matches neither a
          # local user nor a mapped group is refused, which is the deny-by-default
          # AIOStreams wants. Add AIOSTREAMS_OIDC_GROUP_PERMISSIONS if other
          # authelia users should ever get in.
          #
          # Local login stays enabled: it is the way back in if authelia or this
          # mapping breaks, and the built-in proxy and usenet engine authenticate
          # with Basic credentials that an SSO session does not have.
          AIOSTREAMS_OIDC_ALLOW_LOCAL_LOGIN = "true";
        };
        # SECRET_KEY (config encryption — never regenerate, it would make every
        # stored config undecryptable), AIOSTREAMS_AUTH, and the OIDC client
        # secret.
        environmentFiles = [
          "/run/secrets/aiostreams.env"
          "/run/secrets/aiostreams-oidc.env"
        ];
        labels = {
          "io.containers.autoupdate" = "registry";
        };
        # The image ships its own HEALTHCHECK (node → localhost:$PORT/api/v1/status).
        # Unhealthy → podman kills the container; systemd's Restart recreates it.
        extraOptions = [
          "--health-on-failure=kill"
          "--network=container:gluetun"
        ];
      };
    };
  };
}
