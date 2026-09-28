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
# GitOps note: every startup setting lives here or in secrets/sorbet/aiostreams.env.
# Everything else (addons, filters, sorting, formatter) is a *runtime* setting
# that AIOStreams stores in its own SQLite db at /var/lib/aiostreams/db.sqlite —
# that state is not, and cannot be, tracked in this repo.
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
        alerts = [{type = "discord";}];
      }
    ];

    nixosModules.aiostreams = _: {
      sops.secrets."aiostreams.env" = {
        sopsFile = ../secrets/sorbet/aiostreams.env;
        format = "dotenv";
        key = "";
        restartUnits = ["podman-aiostreams.service"];
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
        ];
        environment = {
          TZ = "Europe/Berlin";
          NODE_ENV = "production";
          PORT = "3000";
          BASE_URL = "https://aiostreams.ext.kuipr.de";
          DATABASE_URI = "sqlite://./data/db.sqlite";
          LOG_LEVEL = "info";
          LOG_FORMAT = "json";
        };
        # SECRET_KEY (config encryption — never regenerate, it would make every
        # stored config undecryptable) and AIOSTREAMS_AUTH.
        environmentFiles = ["/run/secrets/aiostreams.env"];
        labels = {
          "io.containers.autoupdate" = "registry";
        };
        extraOptions = [
          "--network=container:gluetun"
        ];
      };
    };
  };
}
