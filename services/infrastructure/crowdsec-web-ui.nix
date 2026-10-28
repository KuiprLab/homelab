# CrowdSec Web UI — dashboard for eclair's CrowdSec engine.
#
# Runs on sorbet, not on eclair. eclair is 1 vCPU / 959 MB and already runs
# pangolin (node API + Next), traefik, gerbil, newt, crowdsec and subtidal. This
# UI is one main process plus four query-workers and one sync-worker — ~350 MB
# for a dashboard that is opened rarely. With it on eclair the pangolin working
# set did not fit: RSS fell while serving, ~500 major faults per request and
# 0.6-3.4 s TTFB cold. With it removed, the dashboard stays resident (0.46 s
# cold, no disk reads when warm) — that is the whole reason for the split.
#
# Networking — the LAPI only exists on eclair, bound to 127.0.0.1:9090
# (`api.server.listen_uri`), because `api.server.trusted_ips` gates alert
# deletion on a 127.0.0.1 source. The pangolin tunnel cannot carry this:
# site newts are userspace proxies with no L3 route (same reason sorbet's Pi-hole
# cannot live on eclair, see services/pihole.nix). The transport is therefore a
# forwarded SSH session from sorbet into eclair's loopback:
#
#   sorbet:crowdsec-lapi-tunnel  ssh -L 127.0.0.1:19090 -> eclair 127.0.0.1:9090
#                                ssh -L 127.0.0.1:19091 -> eclair 127.0.0.1:6060
#
# so the LAPI stays loopback-only, `trusted_ips` needs no change, and the
# connection genuinely originates on eclair's loopback. eclair authorizes a
# dedicated key that may only open those two destinations
# (`restrict,port-forwarding,permitopen=...`).
#
# Port 3010 is deliberately absent from sorbet's firewall: the only way in is
# pangolin's traefik → sorbet's newt → 127.0.0.1:3010. The container shares the
# host netns because a podman bridge has no route to 127.0.0.1:19090.
#
# Auth — Pangolin's SSO (`auth.sso-enabled` on the resource) is the only gate,
# via its Authelia IdP. The app's own login is off (`auth.enabled`), so there is
# no local account, no setup wizard, and no second factor to maintain.
# Consequence to remember: every request that reaches the container is fully
# privileged — the last line of defence is the host firewall (3010 is not open)
# plus the loopback bind.
#
# LAPI credentials — one sops dotenv file feeds both the container and the
# registration oneshot on eclair, which sources the same CONFIG_ variable.
# Rotating the password requires deleting the machine record first
# (`cscli machines delete crowdsec-web-ui`) — the oneshot only adds a missing
# machine and never resets an existing one.
#
# Moving this resource between sites is imperative: blueprint apply creates and
# updates by niceId, it never deletes, so a resource that already exists on the
# eclair site keeps that site binding. Delete `crowdsec` in the pangolin
# dashboard first, then let sorbet's newt create it. The old data directory on
# eclair (/var/lib/crowdsec-web-ui) can be removed afterwards.
_: {
  flake = {
    pangolinVirtualHosts."crowdsec" = {
      site = "sorbet";
      name = "CrowdSec";
      subdomain = "crowdsec.ext.kuipr.de";
      port = 3010;
      private = false;
      # Pangolin gates the browser through its Authelia IdP. `sso-roles` is
      # what makes the resource reachable at all: badger's access check needs
      # a role linked to the resource or its inline policy (pangolin source,
      # server/routers/badger/verifySession.ts:1363-1435). Admin roles are
      # linked implicitly and skipped by the blueprint sync.
      extra.auth = {
        "sso-enabled" = true;
        "sso-roles" = ["Member"];
      };
    };

    # ----- sorbet: tunnel + container -----
    nixosModules.crowdsecWebUi = {
      config,
      lib,
      pkgs,
      ...
    }: {
      sops.secrets."crowdsec-web-ui" = {
        sopsFile = ../../secrets/shared/crowdsec-web-ui.env;
        format = "dotenv";
        key = "";
        owner = "root";
        restartUnits = ["podman-crowdsec-web-ui.service"];
      };

      # Key for the loopback forward into eclair. The matching public key is in
      # eclair's module as a restricted authorized_keys entry.
      sops.secrets."crowdsec-lapi-tunnel.key" = {
        sopsFile = ../../secrets/sorbet/crowdsec-lapi-tunnel.key;
        format = "binary";
        key = "";
        owner = "root";
        mode = "0400";
      };

      # Pinned, not trust-on-first-use: the client verifies eclair's host key.
      environment.etc."crowdsec-lapi-tunnel/known_hosts".text = ''
        eclair.kuipr.de ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOV5Cly7esQDTdNmO0SsgHagaaewbWZeF4g86i17HsJc
      '';

      # Restart=always covers both a dropped session and eclair being down
      # during a deploy. ExitOnForwardFailure keeps a half-open tunnel from
      # looking healthy while 19090/19091 are missing.
      systemd.services.crowdsec-lapi-tunnel = {
        description = "SSH forward to eclair's CrowdSec LAPI";
        wantedBy = ["multi-user.target"];
        after = ["network-online.target"];
        wants = ["network-online.target"];
        serviceConfig = {
          Restart = "always";
          RestartSec = "10s";
          Environment = ["HOME=/root"];
          ExecStart = lib.concatStringsSep " " [
            "${pkgs.openssh}/bin/ssh"
            "-N"
            "-i ${config.sops.secrets."crowdsec-lapi-tunnel.key".path}"
            "-o IdentitiesOnly=yes"
            "-o BatchMode=yes"
            "-o StrictHostKeyChecking=yes"
            "-o UserKnownHostsFile=/etc/crowdsec-lapi-tunnel/known_hosts"
            "-o GlobalKnownHostsFile=/dev/null"
            "-o UpdateHostKeys=no"
            "-o ServerAliveInterval=15"
            "-o ServerAliveCountMax=3"
            "-o ExitOnForwardFailure=yes"
            "-L 127.0.0.1:19090:127.0.0.1:9090"
            "-L 127.0.0.1:19091:127.0.0.1:6060"
            "root@eclair.kuipr.de"
          ];
        };
      };

      virtualisation.oci-containers.containers.crowdsec-web-ui = {
        image = "ghcr.io/theduffman85/crowdsec-web-ui:2026.10.11@sha256:20333d6bc218f274a4cdaabc2e79716d7e203c0a23446c75f6aa6ccfc59a1431";
        volumes = ["/var/lib/crowdsec-web-ui:/app/data:rw"];

        # Non-secret config. The LAPI password is the only CONFIG_ secret and
        # arrives through environmentFiles below.
        environment = {
          # Pangolin is the only gate (see the header). The dashboard's own
          # login stays off, so there is no second account to create or
          # rotate.
          CONFIG_AUTH_ENABLED = "false";

          CONFIG_SERVER_PORT = "3010";

          CONFIG_INSTANCES_0_ID = "eclair";
          CONFIG_INSTANCES_0_NAME = "Eclair";
          CONFIG_INSTANCES_0_LAPI_URL = "http://127.0.0.1:19090";
          CONFIG_INSTANCES_0_LAPI_AUTH_USERNAME = "crowdsec-web-ui";
          # CrowdSec already scrapes itself (prometheus.enabled, level full in
          # /etc/crowdsec/config.yaml) — this is what fills the Metrics tab.
          CONFIG_INSTANCES_0_METRICS_0_ID = "lapi";
          CONFIG_INSTANCES_0_METRICS_0_NAME = "Eclair LAPI";
          CONFIG_INSTANCES_0_METRICS_0_URL = "http://127.0.0.1:19091/metrics";
        };

        environmentFiles = [
          "${config.sops.secrets."crowdsec-web-ui".path}"
        ];

        log-driver = "journald";

        extraOptions = [
          # See the header: the LAPI is only reachable on host loopback.
          "--network=host"
          # Podman does not inherit image HEALTHCHECKs, and the image has no
          # curl — mirror the upstream probe with node. Retry inside the
          # command: podman's first check fires immediately at start, and a
          # failed transient-unit check aborts NixOS activations.
          "--health-cmd=node -e \"const t=Date.now();(async()=>{while(Date.now()-t<25e3){try{if((await fetch('http://127.0.0.1:3010/api/health')).ok)return}catch(e){}await new Promise(r=>setTimeout(r,2e3))}process.exit(1)})()\""
          "--health-interval=30s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=30s"
          "--health-timeout=30s"
        ];
      };

      systemd = {
        tmpfiles.rules = [
          # Container runs as the image's node user (uid/gid 1000). On sorbet
          # uid 1000 is `daniel` — a uid coincidence, not a permission grant.
          "d /var/lib/crowdsec-web-ui 0755 1000 100 -"
        ];

        # No data before the LAPI is reachable. Ordering only: a tunnel restart
        # must not take the container down with it (Restart=always brings the
        # tunnel back and the UI reconnects on its own).
        services.podman-crowdsec-web-ui = {
          after = ["crowdsec-lapi-tunnel.service"];
          wants = ["crowdsec-lapi-tunnel.service"];
        };
      };
    };

    # ----- eclair: LAPI-side half -----
    eclairNixosModules.crowdsecWebUi = {config, ...}: let
      cscli = "${config.services.crowdsec.package}/bin/cscli";
    in {
      sops.secrets."crowdsec-web-ui" = {
        sopsFile = ../../secrets/shared/crowdsec-web-ui.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };

      # sorbet's tunnel key may only open the LAPI and the metrics endpoint.
      # `restrict` drops pty, agent/X11 forwarding, user rc files and command
      # execution; `permitopen` whitelists the forward destinations.
      users.users.root.openssh.authorizedKeys.keys = [
        ''restrict,port-forwarding,permitopen="127.0.0.1:9090",permitopen="127.0.0.1:6060" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKHrJy0LptdihGPCHzzNivs4RkmTkkozzByaKqw2oR3N crowdsec-lapi-tunnel@sorbet''
      ];

      # The dashboard authenticates to LAPI as a registered machine. Watch
      # (never bouncer) credentials, so it can read alerts and manage
      # decisions without joining the enforcement path. Stays on eclair
      # because it writes to the local LAPI, whatever host the UI runs on.
      systemd.services.crowdsec-web-ui-machine = {
        description = "Register the CrowdSec Web UI as a CrowdSec machine";
        wantedBy = ["multi-user.target"];
        after = ["crowdsec.service" "sops-install-secrets.service"];
        wants = ["crowdsec.service"];
        path = [config.services.crowdsec.package];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -eu
          # Shared with the container on sorbet: both read this variable.
          set -a
          . ${config.sops.secrets."crowdsec-web-ui".path}
          set +a

          if ${cscli} machines inspect crowdsec-web-ui >/dev/null 2>&1; then
            echo "machine crowdsec-web-ui already registered"
          else
            ${cscli} machines add crowdsec-web-ui \
              --password "$CONFIG_INSTANCES_0_LAPI_AUTH_PASSWORD" -f /dev/null
          fi
        '';
      };
    };
  };
}
