# Beszel — lightweight server monitoring (hub + agents).
#
# Topology — all-WebSocket token mode, so no agent ever listens on a port:
#   sorbet: hub on 127.0.0.1:8091 (mon.int.kuipr.de client-resource for the
#           UI, monitoring.ext.kuipr.de public proxy-resource for eclair's
#           agent) + local agent (loopback)
#   eclair: agent only, dials the hub through pangolin's public edge
#
# Hub DISABLE_SSH=true → it never dials agents; a disconnected system is
# marked down and waits for the agent to reconnect. Agent DISABLE_SSH=true →
# no SSH server at all. Data flows agent → hub over outbound WebSocket.
# 8090 is taken by Upsnap, hence 8091.
#
# Hub↔agent mutual auth:
#   - agent → hub: universal token (TOKEN in the sops env file). Systems
#     auto-register when agents connect; no per-system SSH keys needed.
#   - agent → hub identity: the agent verifies the hub's WS challenge
#     signature against KEY. The hub's keypair is pre-generated and shipped
#     declaratively (the hub loads <dataDir>/beszel_data/id_ed25519 if
#     present — note the relative "beszel_data" default resolves against
#     the unit's WorkingDirectory — installed via LoadCredential +
#     ExecStartPre), so nothing has to be copied out of the web UI. Without
#     a KEY the 0.18.7 agent binary exits immediately — loadPublicKeys()
#     is unconditional, even with DISABLE_SSH=true.
#
# Setup (one-time, after first sorbet deploy):
#   1. Open https://mon.int.kuipr.de → create the admin user.
#   2. Settings → tokens → create a universal token.
#   3. sops secrets/sorbet/beszel-agent   (replace the placeholder TOKEN)
#      sops secrets/eclair/beszel-agent   (same token)
#   4. Redeploy both hosts. Agents connect and register themselves.
# The agent env files ship with the real KEY + a placeholder TOKEN, so
# deploys work before step 2 — the agent runs and retries until the real
# token lands (a bad token is a 401, not a crash).
_: {
  flake = {
    caddyVirtualHosts."mon.int.kuipr.de" = {
      extraConfig = ''
        reverse_proxy 127.0.0.1:8091
      '';
      name = "Beszel";
    };

    eclairCaddyVirtualHosts."monitoring.ext.kuipr.de" = {
      # Eclair's beszel agent dials the hub over the NetBird overlay: the hub
      # binds the LAN address (beszel.nix), and eclair's caddy reaches it via
      # the masqueraded home-lan network route.
      extraConfig = ''
        reverse_proxy 192.168.0.85:8091
      '';
      name = "Beszel (agent endpoint)";
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
      # Bind the LAN address: eclair's caddy (beszel.nix) reaches the hub
      # through the NetBird overlay via the masqueraded home-lan route — for
      # the wss agent endpoint and the mon UI path. Loopback is no longer
      # enough since the pangolin tunnel is gone.
      services.beszel = {
        hub = {
          enable = true;
          host = "192.168.0.85";
          port = 8091;
          environment = {
            APP_URL = "https://mon.int.kuipr.de";
            DISABLE_SSH = "true";
            USER_CREATION = "true";
          };
        };
        # Local agent still talks to the loopback endpoint (the hub binds
        # the LAN address too, so the port is the same, only the bind differs).
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
