# Notifications are configured in the hub UI (Settings → Notifications), not
# in Nix. For Gotify 3 tokens use the Shoutrrr generic syntax (the legacy
# gotify:// service rejects gtfya.* tokens):
#   generic://gotify.ext.kuipr.de/message?token=<app-token>&@content-type=application/json&template=json
#
# Hub state moved when it became a container: the native unit ran as a
# DynamicUser with StateDirectory=beszel-hub and cwd there, so PocketBase put its
# files in /var/lib/private/beszel-hub/beszel_data. The image runs from /, so its
# data dir is /beszel_data — i.e. the contents of that directory, not the
# directory itself. One manual step on the first deploy (root):
#   install -d -m 0755 /var/lib/beszel
#   cp -a /var/lib/private/beszel-hub/beszel_data/. /var/lib/beszel/
# The hub's ed25519 key is written into that tree from sops on every start, so
# agents keep working without re-registering.
_: {
  flake = {
    pangolinVirtualHosts."monitoring" = {
      site = "sorbet";
      name = "Beszel";
      subdomain = "monitoring.ext.kuipr.de";
      private = false;
      port = 8091;
    };

    # ----- sorbet: hub + local agent -----
    nixosModules.beszel = {
      config,
      lib,
      pkgs,
      ...
    }: {
      sops.secrets."beszel/agent" = {
        sopsFile = ../../secrets/sorbet/beszel-agent;
        format = "binary";
        key = "";
        owner = "root";
      };

      # Hub's ed25519 signing key. Pre-generated (see header) so agents can
      # verify the hub without a key handover through the UI.
      sops.secrets."beszel/hub-key" = {
        sopsFile = ../../secrets/sorbet/beszel-hub-key;
        format = "binary";
        key = "";
        owner = "root";
        mode = "0400";
        restartUnits = ["podman-beszel-hub.service"];
      };

      # Hub runs in the upstream image. PocketBase's data dir is relative to the
      # process cwd ("beszel_data"), and the image's cwd is /, so the bind mount
      # must be at /beszel_data and hold PocketBase's files directly.
      virtualisation.oci-containers.containers.beszel-hub = {
        image = "docker.io/henrygd/beszel:latest@sha256:8514a69d9bbbcb74f371a3205561ee231fc0289739cea64e8131f341d695b770";
        volumes = [
          "/var/lib/beszel:/beszel_data"
        ];
        ports = ["127.0.0.1:8091:8090"]; # image listens on 8090, agents use 8091
        environment = {
          APP_URL = "https://mon.int.kuipr.de";
          DISABLE_SSH = "true";
          USER_CREATION = "true";
        };
        log-driver = "journald";
        # No container healthcheck: the image is FROM scratch (no shell, no
        # curl/wget), so there is nothing for --health-cmd to run. The unit's
        # Restart covers a crash; the pocketbase data dir is the only state.
      };

      systemd = {
        tmpfiles.rules = ["d /var/lib/beszel 0755 root root - -"];

        services."podman-beszel-hub" = {
          serviceConfig = {
            Restart = lib.mkOverride 90 "always";
            # LoadCredential and $CREDENTIALS_DIRECTORY do not reach into the
            # container, so hand the key in through the data dir instead.
            ExecStartPre = [
              (pkgs.writeShellScript "beszel-hub-install-key" ''
                install -Dm 600 ${config.sops.secrets."beszel/hub-key".path} \
                  /var/lib/beszel/id_ed25519
              '')
            ];
          };
        };
      };

      # Hub is loopback-only: the UI resource proxies to 127.0.0.1 and the
      # public ws endpoint does too — nothing binds the LAN beyond that.
      services.beszel = {
        agent = {
          enable = true;
          # S.M.A.R.T. data for the NVMe + btrfs disks. Grants the agent
          # disk group + raw-IO caps (smartmontools is put on its path).
          smartmon.enable = true;
          environment = {
            HUB_URL = "http://127.0.0.1:8091";
            DISABLE_SSH = "true";
          };
          # KEY + TOKEN (both required — see header). Lives in the sops
          # env file, not plain environment: the upstream module warns that
          # freeform env ends up world-readable in /nix/store.
          environmentFile = config.sops.secrets."beszel/agent".path;
        };
      };
    };

    # ----- eclair: agent only -----
    eclairNixosModules.beszelAgent = {config, ...}: {
      sops.secrets."beszel/agent" = {
        sopsFile = ../../secrets/eclair/beszel-agent;
        format = "binary";
        key = "";
        owner = "root";
      };

      services.beszel.agent = {
        enable = true;
        environment = {
          # Through pangolin's public proxy-resource (TLS terminated by
          # pangolin; agent verifies the wildcard cert, then dials wss).
          HUB_URL = "https://monitoring.ext.kuipr.de";
          DISABLE_SSH = "true";
        };
        # KEY + TOKEN (both required — see sorbet module header).
        environmentFile = config.sops.secrets."beszel/agent".path;
      };
    };
  };
}
