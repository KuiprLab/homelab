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
      };

      systemd.services.beszel-hub.serviceConfig = {
        # Hand the private key to the (DynamicUser) hub service without
        # weakening the sandbox.
        LoadCredential = ["id_ed25519:${config.sops.secrets."beszel/hub-key".path}"];
        # The hub generates a keypair only if <dataDir>/beszel_data/
        # id_ed25519 is missing (PocketBase resolves its relative default
        # "beszel_data" against WorkingDirectory) — install ours (as the
        # service user, which owns the StateDirectory) before it starts.
        ExecStartPre = [
          (pkgs.writeShellScript "beszel-hub-install-key" ''
            install -Dm 600 "$CREDENTIALS_DIRECTORY/id_ed25519" \
              "${toString config.services.beszel.hub.dataDir}/beszel_data/id_ed25519"
          '')
        ];
      };

      # Hub is loopback-only: the UI resource proxies to 127.0.0.1 and the
      # public ws endpoint does too — nothing binds the LAN beyond that.
      services.beszel = {
        hub = {
          enable = true;
          host = "127.0.0.1";
          port = 8091;
          environment = {
            APP_URL = "https://mon.int.kuipr.de";
            DISABLE_SSH = "true";
            USER_CREATION = "true";
          };
        };
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
