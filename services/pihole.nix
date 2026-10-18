# Minimal Pi-hole (DNS + ad blocking) on sorbet.
#
# Stripped-down successor of the removed pihole/doh module (caddy gone, no
# DoH shim): one container, published on loopback only, LAN dnsmasq
# forwards to it. Everything is LAN-local — nothing depends on tailscale
# or the pangolin tunnel (site tunnels are userspace proxies, no L3 route,
# so a pihole on eclair is unreachable from here).
#
# Consumers:
#   1. LAN dnsmasq (dns-dhcp module) forwards unresolved names to
#      127.0.0.1#5353 → every LAN lookup gets ad blocking + FTL query log.
#   2. LAN rules resolve *.int.kuipr.de via the wildcard address line
#      below (single authority, same as before the tailscale migration).
{lib, ...}: let
  # Declarative blocklist set. Edit here and redeploy.
  blocklists = [
    {
      address = "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts";
      comment = "StevenBlack unified hosts (ads + malware)";
    }
    {
      address = "https://big.oisd.nl";
      comment = "OISD big";
    }
  ];
in {
  flake.nixosModules.pihole = {
    lib,
    pkgs,
    ...
  }: let
    blocklistsFile = pkgs.writeText "pihole-blocklists.json" (
      builtins.toJSON blocklists
    );

    # Script: converge gravity.db's list set to the declarative one, then
    # refresh. Runs only when the set's content hash changes.
    applyBlocklists = pkgs.writeShellScript "pihole-apply-blocklists" ''
      set -euo pipefail

      STATE_DIR=/var/lib/pihole
      HASH_FILE="$STATE_DIR/.blocklists.hash"
      NEW_HASH="$(${pkgs.coreutils}/bin/sha256sum ${blocklistsFile} | ${pkgs.coreutils}/bin/cut -d' ' -f1)"

      if [[ -f "$HASH_FILE" && "$(< "$HASH_FILE")" == "$NEW_HASH" ]]; then
        echo "blocklist set unchanged"
        exit 0
      fi

      # Wait for FTL's webserver (container may still be starting).
      for _ in $(${pkgs.coreutils}/bin/seq 1 30); do
        if ${pkgs.curl}/bin/curl -fsS -o /dev/null http://127.0.0.1:8090/api/lists; then
          break
        fi
        sleep 2
      done

      CUR="$(${pkgs.curl}/bin/curl -fsS http://127.0.0.1:8090/api/lists)"

      # Remove block-type lists that are not in the declarative set
      # (UI-added adlists are removed on the next run).
      TO_DELETE="$(${pkgs.jq}/bin/jq -c --slurpfile want ${blocklistsFile} '
        [.lists[]
          | select(.type == "block")
          | select(.address as $a | $want[0] | map(.address) | index($a) | not)
          | {item: .address, type: "block"}]' <<<"$CUR")"
      if [[ "$TO_DELETE" != "[]" ]]; then
        # FTL's batch operations are colon-routed (/api/lists:batchDelete);
        # a slash is parsed as /api/lists/<item> and rejected with a 400.
        ${pkgs.curl}/bin/curl -fsS -X POST http://127.0.0.1:8090/api/lists:batchDelete \
          -H 'Content-Type: application/json' -d "$TO_DELETE" >/dev/null
      fi

      # Add missing declarative lists (POST is idempotent-checked against
      # the set we just fetched — no duplicate-list 400s).
      ${pkgs.jq}/bin/jq -r '.[].address' ${blocklistsFile} | while read -r ADDR; do
        if ! ${pkgs.jq}/bin/jq -e --arg a "$ADDR" \
            '.lists[] | select(.type == "block" and .address == $a)' <<<"$CUR" >/dev/null; then
          COMMENT="$(${pkgs.jq}/bin/jq -r --arg a "$ADDR" \
            '[.[] | select(.address == $a)][0].comment' ${blocklistsFile})"
          ${pkgs.curl}/bin/curl -fsS -X POST 'http://127.0.0.1:8090/api/lists?type=block' \
            -H 'Content-Type: application/json' \
            -d "$(${pkgs.jq}/bin/jq -n --arg a "$ADDR" --arg c "$COMMENT" \
              '{address: $a, comment: $c}')" >/dev/null
        fi
      done

      echo "$NEW_HASH" > "$HASH_FILE"

      # Pull the (possibly new) lists into the blocking table now instead
      # of waiting for the weekly gravity timer.
      ${pkgs.podman}/bin/podman exec pihole pihole -g
    '';
  in {
    systemd = {
      services = {
        # Converge the declarative blocklist set into gravity.db, then
        # refresh. Runs on boot (covers image pulls on a fresh host) and
        # whenever the set's hash changes.
        pihole-blocklists = {
          description = "Pi-hole declarative blocklist convergence";
          wantedBy = ["multi-user.target"];
          after = ["podman-pihole.service"];
          requires = ["podman-pihole.service"];
          # The REST API is open (no webserver password — see the
          # container env below), so the script needs no credentials.
          serviceConfig = {
            Type = "oneshot";
            ExecStart = applyBlocklists;
            RemainAfterExit = true;
          };
        };

        # Weekly gravity refresh so upstream list content stays fresh.
        pihole-gravity = {
          description = "Pi-hole gravity update";
          after = ["podman-pihole.service"];
          requires = ["podman-pihole.service"];
          serviceConfig = {
            Type = "oneshot";
            ExecStart = "${pkgs.podman}/bin/podman exec pihole pihole -g";
          };
          startAt = "Sun 03:00";
        };
      };

      tmpfiles.rules = ["d /var/lib/pihole 0700 root root -"];
    };

    virtualisation = {
      podman.enable = true;
      oci-containers.backend = "podman";
      oci-containers.containers.pihole = {
        image = "docker.io/pihole/pihole:2026.09.0@sha256:bd3fc82ee1b1473a45fc074379dcd9fd7ce3e933809c44e10c0df9b22fd5de63";
        autoStart = true;
        environment = {
          TZ = "Europe/Berlin";

          # Deliberate empty password → no FTL login/API auth. The docker
          # image ships a default password hash in its baked-in
          # pihole.toml, so this empty value is load-bearing: it clears
          # webserver.api.password. The blocklist script relies on the
          # open API. The dashboard itself is NOT published to the tunnel
          # network — FTL answers GET /api/auth with
          # {"session":{"valid":true,"message":"no password set"}}
          # on loopback only.
          FTLCONF_webserver_api_password = "";

          # Upstream resolvers (newline-separated arrays, not JSON).
          FTLCONF_dns_upstreams = "1.1.1.1;9.9.9.9";

          # ALL: the published-port path forwards to the container's eth0,
          # "local-only" listening mode refuses. Required even for the
          # loopback publish.
          FTLCONF_dns_listeningMode = "ALL";

          # Names for every client that can reach FTL, so the dashboard
          # shows hosts instead of bare addresses. Local host services
          # bypass FTL (sorbet resolves via 9.9.9.9, see configuration.nix).

          # Names for every client that can reach FTL, so the dashboard
          # shows hosts instead of bare addresses.
          FTLCONF_dns_hosts = "192.168.0.85 sorbet;192.168.0.5 tiramisu;10.88.0.1 pangolin-clients;100.89.128.1 eclair-gerbil;100.89.128.12 sorbet-newt";

          # Split horizon: *.int.kuipr.de (and the domain itself) answer
          # with sorbet from anywhere. This is the single wildcard
          # authority now — sorbet's dnsmasq no longer answers .int
          # locally and forwards here instead.
          FTLCONF_misc_dnsmasq_lines = "address=/int.kuipr.de/192.168.0.85";
        };
        volumes = [
          "/var/lib/pihole:/etc/pihole:rw"
        ];
        ports = [
          # DNS + dashboard: loopback only. dnsmasq (enp0s31f6:53) is the
          # LAN frontend and forwards to 127.0.0.1#5353; nothing on the
          # LAN talks to FTL directly.
          "127.0.0.1:5353:53/tcp"
          "127.0.0.1:5353:53/udp"
          "127.0.0.1:8090:80/tcp"
        ];
        # Podman does not inherit image HEALTHCHECKs — mirror the
        # upstream one (dig pi.hole, no recursion needed). The command
        # must ride out FTL's own startup: podman runs healthchecks as
        # transient systemd units (subtidal pattern), and deploy-rs
        # aborts activation on ANY failed unit — so the first tick,
        # which fires while FTL is still booting, retries a few times
        # before reporting failure. Unhealthy → podman kills the
        # container; systemd's Restart recreates it (same as subtidal).
        extraOptions = [
          "--health-cmd=dig -p 53 +short +norecurse +retry=0 @127.0.0.1 pi.hole >/dev/null || { for _ in 1 2 3; do sleep 3; dig -p 53 +short +norecurse +retry=0 @127.0.0.1 pi.hole >/dev/null && exit 0; done; exit 1; }"
          "--health-interval=60s"
          "--health-on-failure=kill"
          "--health-retries=3"
          "--health-start-period=30s"
          "--health-timeout=15s"
          # podman injects "10.88.0.1 host.containers.internal" into the
          # container's /etc/hosts, which beats FTLCONF_dns_hosts in FTL's
          # reverse lookup — the published-port client would stay named
          # host.containers.internal. --no-hosts drops podman's entries;
          # FTL then names the client from FTLCONF_dns_hosts (pangolin-clients).
          # The healthcheck and FTL only use numeric addresses, so nothing
          # inside the container needs name resolution.
          "--no-hosts"
        ];
      };
    };
  };
}
