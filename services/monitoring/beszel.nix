# Notifications are set in the hub UI; Gotify 3 tokens need the Shoutrrr generic:// syntax.
{config, ...}: let
  proxyIp = "10.89.0.62";
  vhost = config.flake.pangolinVirtualHosts."monitoring";
  labels =
    config.flake.pangolinRuleLabels "monitoring"
    // config.flake.pangolinHealthcheckLabels "monitoring" vhost
    // config.flake.pangolinPublicLabels "monitoring" vhost;
in {
  flake = {
    podmanProxyHosts.beszel-hub.ip = proxyIp;

    pangolinVirtualHosts."monitoring" = {
      site = "sorbet";
      name = "Beszel";
      subdomain = "monitoring.ext.kuipr.de";
      private = false;
      hostname = "beszel-hub";
      port = 8090;
    };

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

      sops.secrets."beszel/hub-key" = {
        sopsFile = ../../secrets/sorbet/beszel-hub-key;
        format = "binary";
        key = "";
        owner = "root";
        mode = "0400";
        restartUnits = ["podman-beszel-hub.service"];
      };

      # PocketBase's data dir is relative to cwd, and the image's cwd is /.
      virtualisation.oci-containers.containers.beszel-hub = {
        inherit labels;
        image = "docker.io/henrygd/beszel:latest@sha256:b0be90bd4aee2993fde763032a5098ce4386fba43cfe5031ec017b8d9e8c97a2";
        volumes = [
          "/var/lib/beszel:/beszel_data"
        ];
        environment = {
          APP_URL = "https://${vhost.subdomain}";
          DISABLE_SSH = "true";
          USER_CREATION = "true";
          DISABLE_PASSWORD_AUTH = "false"; # needed for home assistant integration
          SHARE_ALL_SYSTEMS = "true";
        };
        log-driver = "journald";
        extraOptions = ["--network=proxy:ip=${proxyIp}"];
        # The image is FROM scratch, so there is nothing for --health-cmd to run.
      };

      systemd = {
        tmpfiles.rules = ["d /var/lib/beszel 0755 root root - -"];

        services."podman-beszel-hub" = {
          serviceConfig = {
            Restart = lib.mkOverride 90 "always";
            # Credentials dir does not reach into the container.
            ExecStartPre = [
              (pkgs.writeShellScript "beszel-hub-install-key" ''
                install -Dm 600 ${config.sops.secrets."beszel/hub-key".path} \
                  /var/lib/beszel/id_ed25519
              '')
            ];
          };
        };
      };

      services.beszel = {
        agent = {
          enable = true;
          smartmon.enable = true;
          environment = {
            HUB_URL = "http://beszel-hub:8090";
            DISABLE_SSH = "true";
          };
          # sops env file: freeform env would end up world-readable in /nix/store.
          environmentFile = config.sops.secrets."beszel/agent".path;
        };
      };

      # The unit's default Restart=on-failure leaves the agent dead for good if it
      # starts before the hub is reachable and exits cleanly.
      systemd.services.beszel-agent = {
        wants = ["podman-beszel-hub.service"];
        after = ["podman-beszel-hub.service"];
        serviceConfig.Restart = lib.mkOverride 90 "always";
      };
    };

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
          HUB_URL = "https://monitoring.ext.kuipr.de";
          DISABLE_SSH = "true";
        };
        environmentFile = config.sops.secrets."beszel/agent".path;
      };
    };
  };
}
