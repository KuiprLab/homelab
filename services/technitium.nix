# Technitium DNS Server on sorbet: LAN resolver, ad/malware blocker and DHCP
# server for 192.168.0.0/24. One process is authoritative for both DNS and DHCP
# on the LAN; nothing forwards to a second resolver.
#
# The nixpkgs module (services.technitium-dns-server) only defines the unit; it
# has no configuration options. Everything else lives in Technitium's mutable
# state dir and is applied by technitium-converge.service through the REST API:
# forwarders, blocking, the int.kuipr.de zone, the DHCP scope. The unit writes
# the full desired state on boot and whenever this file changes; every call is
# an idempotent overwrite, not an append.
#
# Bootstrap: the unit passes the sops password as
# DNS_SERVER_ADMIN_PASSWORD, which Technitium only honours while it creates
# auth.config on a fresh state dir. The converge script still falls back to the
# built-in admin/admin login once, for a state dir created before this wiring.
#
# Consumers:
#   * DHCP hands 192.168.0.85 out as resolver for the LAN (option 6).
#   * Container workloads pin --dns=192.168.0.85, so their queries are logged
#     under their podman IP instead of aardvark's gateway address.
#   * *.int.kuipr.de resolves to sorbet (wildcard record in a primary zone),
#     where caddy terminates TLS.
#   * If the server crash-loops, dnsmasq takes over the LAN
#     (services/infrastructure/dns-fallback.nix).
_: let
  serverIp = "192.168.0.85";
  zone = "int.kuipr.de";

  # Declarative blocklist set. Edit here and redeploy; Technitium re-downloads
  # the lists itself every blockListUpdateIntervalHours.
  blocklists = [
    "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
    "https://big.oisd.nl"
  ];

  settings = {
    # SOA/NS name of this server inside the local zone.
    dnsServerDomain = "sorbet.${zone}";
    # Never bind the wildcard. podman's aardvark-dns and incus' dnsmasq hold
    # :53 on their bridge addresses, and a 0.0.0.0 bind (the Technitium
    # default) then fails with EADDRINUSE. These are the only two addresses
    # that need to answer: the LAN and the host itself.
    dnsServerLocalEndPoints = "${serverIp}:53,127.0.0.1:53";
    # Forwarding (not recursion): the upstream behaviour stays as it was.
    forwarders = "1.1.1.1,9.9.9.9";
    forwarderProtocol = "Udp";
    # Every query is logged: the dashboard is the blocking audit trail.
    logQueries = true;
    # Web console and REST API on loopback only. caddy serves
    # technitium.int.kuipr.de from there; nothing on the LAN reaches 5380.
    webServiceLocalAddresses = "127.0.0.1";
    enableBlocking = true;
    # AnyAddress answers 0.0.0.0/:: for blocked names (NULL blocking).
    blockingType = "AnyAddress";
    blockListUrls = builtins.concatStringsSep "," blocklists;
    blockListUpdateIntervalHours = 24;
  };

  dhcpScope = {
    name = "lan";
    startingAddress = "192.168.0.2";
    endingAddress = "192.168.0.254";
    subnetMask = "255.255.255.0";
    # 24 h leases: the API rejects hours outside 0-23.
    leaseTimeDays = 1;
    leaseTimeHours = 0;
    routerAddress = "192.168.0.1";
  };

  # Static identities for the infrastructure hosts.
  reservedLeases = [
    {
      hardwareAddress = "18:31:bf:b7:fd:3f";
      ipAddress = serverIp;
      hostName = "sorbet";
    }
    {
      hardwareAddress = "74:56:3c:30:fc:b7";
      ipAddress = "192.168.0.5";
      hostName = "tiramisu";
    }
  ];
in {
  flake.pangolinVirtualHosts."technitium" = {
    site = "sorbet";
    name = "Technitium DNS";
    subdomain = "technitium.int.kuipr.de";
    port = 5380;
  };

  flake.nixosModules.technitium = {
    config,
    lib,
    pkgs,
    ...
  }: let
    converge = pkgs.writeShellApplication {
      name = "technitium-converge";
      runtimeInputs = [pkgs.coreutils pkgs.curl pkgs.jq];
      text = ''
        BASE=http://127.0.0.1:5380/api
        ZONE=${zone}
        SERVER_IP=${serverIp}
        SCOPE_NAME=${dhcpScope.name}
        SETTINGS_JSON=${lib.escapeShellArg (builtins.toJSON settings)}
        LEASES_JSON=${lib.escapeShellArg (builtins.toJSON reservedLeases)}

        set -a
        # shellcheck disable=SC1091
        . ${config.sops.secrets."technitium.env".path}
        set +a
        password="$DNS_SERVER_ADMIN_PASSWORD"

        login() {
          curl -fsS --max-time 10 -G "$BASE/user/login" \
            --data-urlencode user=admin \
            --data-urlencode "pass=$1" 2>/dev/null \
            | jq -r 'select(.status == "ok") | .token // empty' || true
        }

        # Technitium binds its web service late on a cold boot. Wait for it
        # without logging in: five failed logins from one address block the
        # client for 300 seconds, which would lock out the bootstrap below.
        ready=false
        for _ in $(seq 1 60); do
          if curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:5380/ 2>/dev/null; then
            ready=true
            break
          fi
          sleep 2
        done
        if [ "$ready" != true ]; then
          echo "technitium web service is not reachable on 5380" >&2
          exit 1
        fi

        token="$(login "$password")"
        if [ -z "$token" ]; then
          # State dir created before DNS_SERVER_ADMIN_PASSWORD was wired up: the
          # built-in admin/admin login is still active exactly once.
          session="$(login admin)"
          if [ -n "$session" ]; then
            curl -fsS --max-time 10 -G -H "Authorization: Bearer $session" \
              "$BASE/user/changePassword" \
              --data-urlencode pass=admin \
              --data-urlencode "newPass=$password" >/dev/null
            token="$(login "$password")"
          fi
        fi
        if [ -z "$token" ]; then
          echo "technitium rejected the sops admin password" >&2
          exit 1
        fi

        api() {
          local path=$1
          shift
          curl -fsS --max-time 30 -G -H "Authorization: Bearer $token" "$BASE$path" "$@"
        }

        # apply <path> [args...]: one API call that must report status ok.
        apply() {
          local path=$1 response
          shift
          response="$(api "$path" "$@")"
          if ! jq -e '.status == "ok"' >/dev/null <<<"$response"; then
            echo "technitium API call $path failed: $response" >&2
            exit 1
          fi
          printf '%s' "$response"
        }

        # --- DNS settings ---------------------------------------------------
        # Each parameter is an overwrite of the current value, so sending the
        # full desired set every run converges instead of accumulating.
        set_args=()
        while IFS=$'\t' read -r key value; do
          set_args+=(--data-urlencode "$key=$value")
        done < <(jq -r 'to_entries[] | [.key, (.value | tostring)] | @tsv' <<<"$SETTINGS_JSON")

        before="$(api /settings/get | jq -r '(.response.blockListUrls // []) | join(",")')"
        updated="$(apply /settings/set "''${set_args[@]}")"
        after="$(jq -r '(.response.blockListUrls // []) | join(",")' <<<"$updated")"

        # Download the lists now only when the set changed; otherwise the
        # server refreshes them on its own schedule.
        if [ "$after" != "$before" ]; then
          apply /settings/forceUpdateBlockLists >/dev/null
        fi

        # --- int.kuipr.de ---------------------------------------------------
        # An existing zone makes this call fail, which is the steady state.
        api /zones/create \
          --data-urlencode "zone=$ZONE" \
          --data-urlencode type=Primary >/dev/null 2>&1 || true

        # overwrite=true assigns the record set instead of appending a second A
        # record on every run. The wildcard is the LAN split-horizon for every
        # *.int.kuipr.de name.
        for domain in "$ZONE" "*.$ZONE"; do
          apply /zones/records/add \
            --data-urlencode "zone=$ZONE" \
            --data-urlencode "domain=$domain" \
            --data-urlencode type=A \
            --data-urlencode "ipAddress=$SERVER_IP" \
            --data-urlencode ttl=300 \
            --data-urlencode overwrite=true >/dev/null
        done

        # --- DHCP scope -----------------------------------------------------
        # A fresh state dir ships a `Default` scope (192.168.1.0/24). Two enabled
        # scopes on one interface is a coin flip, so drop it.
        api /dhcp/scopes/delete --data-urlencode name=Default >/dev/null 2>&1 || true

        apply /dhcp/scopes/set \
          --data-urlencode "name=$SCOPE_NAME" \
          --data-urlencode "startingAddress=${dhcpScope.startingAddress}" \
          --data-urlencode "endingAddress=${dhcpScope.endingAddress}" \
          --data-urlencode "subnetMask=${dhcpScope.subnetMask}" \
          --data-urlencode "leaseTimeDays=${toString dhcpScope.leaseTimeDays}" \
          --data-urlencode "leaseTimeHours=${toString dhcpScope.leaseTimeHours}" \
          --data-urlencode "routerAddress=${dhcpScope.routerAddress}" \
          --data-urlencode "dnsServers=$SERVER_IP" \
          --data-urlencode blockLocallyAdministeredMacAddresses=false >/dev/null

        scope="$(api /dhcp/scopes/get --data-urlencode "name=$SCOPE_NAME" 2>/dev/null || true)"
        while IFS=$'\t' read -r mac address host; do
          # The API answers hardware addresses with dashes, the scope set call
          # takes colons: normalise both sides before comparing.
          present="$(jq -r --arg mac "$mac" \
            '[(.response.reservedLeases // [])[]
              | select((((.hardwareAddress // "") | ascii_upcase) | gsub("-"; ":")) == ($mac | ascii_upcase))] | length' \
            <<<"$scope" 2>/dev/null || echo 0)"
          [ "$present" = "0" ] || continue
          apply /dhcp/scopes/addReservedLease \
            --data-urlencode "name=$SCOPE_NAME" \
            --data-urlencode "hardwareAddress=$mac" \
            --data-urlencode "ipAddress=$address" \
            --data-urlencode "hostName=$host" >/dev/null
        done < <(jq -r '.[] | [.hardwareAddress, .ipAddress, .hostName] | @tsv' <<<"$LEASES_JSON")

        # Enabling an already-enabled scope is undocumented, so tolerate a
        # rejection here and verify the end state through the scope list.
        api /dhcp/scopes/enable --data-urlencode "name=$SCOPE_NAME" >/dev/null 2>&1 || true
        enabled="$(api /dhcp/scopes/list \
          | jq -r --arg name "$SCOPE_NAME" '[.response.scopes[] | select(.name == $name)][0].enabled // false')"
        if [ "$enabled" != "true" ]; then
          echo "DHCP scope $SCOPE_NAME is not enabled" >&2
          exit 1
        fi

        echo "converged: dns settings, $ZONE zone, dhcp scope $SCOPE_NAME"
      '';
    };
  in {
    sops.secrets."technitium.env" = {
      sopsFile = ../secrets/sorbet/technitium.env;
      format = "dotenv";
      key = "";
      owner = "root";
    };

    services.technitium-dns-server.enable = true;
    # Ports are opened by services/infrastructure/dns-fallback.nix.
    # DHCP serves as soon as the scope exists, so the unit must not start before
    # enp0s31f6 has its address; the module only orders against network.target.
    systemd.services.technitium-dns-server = {
      after = ["network-online.target"];
      wants = ["network-online.target"];
      # Only read while Technitium creates auth.config on a fresh state dir;
      # afterwards the password lives in auth.config.
      serviceConfig.EnvironmentFile = config.sops.secrets."technitium.env".path;
    };

    systemd.services.technitium-converge = {
      description = "Converge Technitium DNS/DHCP state through its REST API";
      wantedBy = ["multi-user.target"];
      after = ["technitium-dns-server.service"];
      requires = ["technitium-dns-server.service"];
      serviceConfig = {
        Type = "oneshot";
        # Changed ExecStart (this file edited) restarts the unit on switch.
        RemainAfterExit = true;
        ExecStart = lib.getExe converge;
      };
    };
  };
}
