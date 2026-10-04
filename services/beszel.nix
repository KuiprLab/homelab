# Beszel — lightweight server monitoring (hub + agents).
#
# Topology — all-WebSocket token mode, so no agent ever listens on a port:
#   sorbet: hub on 0.0.0.0:8091 (caddy → mon.int.kuipr.de, loopback for the
#           local agent, tailscale0 for eclair — firewall-limited) + agent
#   eclair: agent only, dials the hub over the tailnet
#
# Hub DISABLE_SSH=true → it never dials agents; a disconnected system is
# marked down and waits for the agent to reconnect. Agent DISABLE_SSH=true →
# no SSH server at all. Data flows agent → hub over outbound WebSocket.
# 8090 is taken by Upsnap, hence 8091.
#
# Agent auth uses the universal token (hub UI: /settings/tokens) instead of
# per-system SSH keys, so systems auto-register when agents connect.
#
# Setup (one-time, after first sorbet deploy):
#   1. Open https://mon.int.kuipr.de → create the admin user.
#   2. Settings → tokens → create a universal token.
#   3. sops secrets/sorbet/beszel-agent   (content: TOKEN=<token>)
#      sops secrets/eclair/beszel-agent   (same token)
#   4. Redeploy both hosts. Agents connect and register themselves.
# The files are pre-encrypted with a placeholder so deploys work before
# step 2; agents just retry until the real token lands.
_: {
  flake = {
    # ----- sorbet: hub + local agent -----
    nixosModules.beszel = {config, ...}: {
      sops.secrets."beszel/agent" = {
        sopsFile = ../secrets/sorbet/beszel-agent;
        format = "binary";
        key = "";
        owner = "root";
      };

      # Hub must be reachable from eclair over the tailnet (agent WS +
      # gatus cross-probe). interfaces-scoped, so the LAN can't hit 8091;
      # caddy talks to it over loopback, which nftables doesn't filter.
      networking.firewall.interfaces."tailscale0".allowedTCPPorts = [8091];

      services.beszel = {
        hub = {
          enable = true;
          # Bind all interfaces: loopback for caddy + the local agent,
          # tailscale0 for eclair. Firewall keeps the LAN out.
          host = "0.0.0.0";
          port = 8091;
          environment = {
            APP_URL = "https://mon.int.kuipr.de";
            DISABLE_SSH = "true";
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
          environmentFile = config.sops.secrets."beszel/agent".path;
        };
      };
    };

    # ----- eclair: agent only -----
    eclairNixosModules.beszelAgent = {config, ...}: {
      sops.secrets."beszel/agent" = {
        sopsFile = ../secrets/eclair/beszel-agent;
        format = "binary";
        key = "";
        owner = "root";
      };

      services.beszel.agent = {
        enable = true;
        environment = {
          # Direct tailnet path to the hub — eclair's dnsmasq-less VPS
          # can't resolve *.int.kuipr.de, and this skips caddy entirely.
          HUB_URL = "http://100.120.32.9:8091";
          DISABLE_SSH = "true";
        };
        environmentFile = config.sops.secrets."beszel/agent".path;
      };
    };

    # Dashboard, not authelia'd — beszel has its own login (PocketBase),
    # consistent with up.int.kuipr.de's trust model.
    caddyVirtualHosts."mon.int.kuipr.de" = {
      extraConfig = ''
        reverse_proxy 127.0.0.1:8091
      '';
      name = "Beszel";
    };

    gatusEndpoints = [
      {
        name = "Beszel";
        group = "Monitoring";
        # PocketBase health endpoint, public — no authelia to bypass.
        url = "https://mon.int.kuipr.de/api/health";
        interval = "60s";
        conditions = [
          "[STATUS] == 200"
          "[CERTIFICATE_EXPIRATION] > 168h"
          "[RESPONSE_TIME] < 1500"
        ];
        alerts = [{type = "discord";}];
      }
    ];
  };
}
