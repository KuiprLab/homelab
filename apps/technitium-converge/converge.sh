#!/usr/bin/env bash
# Converge Technitium DNS/DHCP state through its REST API.
#
# The nixpkgs module (services.technitium-dns-server) only defines the unit; it
# has no configuration options. Everything else lives in Technitium's mutable
# state dir and is applied here: forwarders, blocking, the int.kuipr.de zone,
# the DHCP scope, the Authelia OIDC login. Every call is an idempotent
# overwrite, not an append, so the unit can run on every boot and on every
# change.
#
# Bootstrap: the server unit passes the sops password as
# DNS_SERVER_ADMIN_PASSWORD, which Technitium only honours while it creates
# auth.config on a fresh state dir. The converge script still falls back to the
# built-in admin/admin login once, for a state dir created before this wiring.
#
# The desired state arrives as environment variables from the unit (see
# _module.nix); this file carries none of its own.

set -euo pipefail

base="$TECHNITIUM_API_URL"
zone="$TECHNITIUM_ZONE"
server_ip="$TECHNITIUM_SERVER_IP"
desired="$TECHNITIUM_DESIRED_JSON"
settings_json=$(jq -c .settings <<<"$desired")
leases_json=$(jq -c .reservedLeases <<<"$desired")
scope_name=$(jq -r .dhcpScope.name <<<"$desired")
sso_authority=$(jq -r .sso.authority <<<"$desired")
sso_client_id=$(jq -r .sso.clientId <<<"$desired")
sso_scopes=$(jq -r .sso.scopes <<<"$desired")
sso_group_map=$(jq -r .sso.groupMap <<<"$desired")

set -a
# shellcheck disable=SC1090,SC1091
. "$TECHNITIUM_ENV_FILE"
set +a
password="$DNS_SERVER_ADMIN_PASSWORD"

login() {
  curl -fsS --max-time 10 -G "$base/user/login" \
    --data-urlencode user=admin \
    --data-urlencode "pass=$1" 2>/dev/null |
    jq -r 'select(.status == "ok") | .token // empty' || true
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
      "$base/user/changePassword" \
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
  curl -fsS --max-time 30 -G -H "Authorization: Bearer $token" "$base$path" "$@"
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

# --- DNS settings -------------------------------------------------------
# Each parameter is an overwrite of the current value, so sending the
# full desired set every run converges instead of accumulating.
set_args=()
while IFS=$'\t' read -r key value; do
  set_args+=(--data-urlencode "$key=$value")
done < <(jq -r 'to_entries[] | [.key, (.value | tostring)] | @tsv' <<<"$settings_json")

before="$(api /settings/get | jq -r '(.response.blockListUrls // []) | join(",")')"
updated="$(apply /settings/set "${set_args[@]}")"
after="$(jq -r '(.response.blockListUrls // []) | join(",")' <<<"$updated")"

# Download the lists now only when the set changed; otherwise the
# server refreshes them on its own schedule.
if [ "$after" != "$before" ]; then
  apply /settings/forceUpdateBlockLists >/dev/null
fi

# --- int.kuipr.de -------------------------------------------------------
# An existing zone makes this call fail, which is the steady state.
api /zones/create \
  --data-urlencode "zone=$zone" \
  --data-urlencode type=Primary >/dev/null 2>&1 || true

# overwrite=true assigns the record set instead of appending a second A
# record on every run. The wildcard is the LAN split-horizon for every
# *.int.kuipr.de name.
for domain in "$zone" "*.$zone"; do
  apply /zones/records/add \
    --data-urlencode "zone=$zone" \
    --data-urlencode "domain=$domain" \
    --data-urlencode type=A \
    --data-urlencode "ipAddress=$server_ip" \
    --data-urlencode ttl=300 \
    --data-urlencode overwrite=true >/dev/null
done

# --- DHCP scope ---------------------------------------------------------
# A fresh state dir ships a `Default` scope (192.168.1.0/24). Two enabled
# scopes on one interface is a coin flip, so drop it.
api /dhcp/scopes/delete --data-urlencode name=Default >/dev/null 2>&1 || true

apply /dhcp/scopes/set \
  --data-urlencode "name=$scope_name" \
  --data-urlencode "startingAddress=$(jq -r .dhcpScope.startingAddress <<<"$desired")" \
  --data-urlencode "endingAddress=$(jq -r .dhcpScope.endingAddress <<<"$desired")" \
  --data-urlencode "subnetMask=$(jq -r .dhcpScope.subnetMask <<<"$desired")" \
  --data-urlencode "leaseTimeDays=$(jq -r .dhcpScope.leaseTimeDays <<<"$desired")" \
  --data-urlencode "leaseTimeHours=$(jq -r .dhcpScope.leaseTimeHours <<<"$desired")" \
  --data-urlencode "routerAddress=$(jq -r .dhcpScope.routerAddress <<<"$desired")" \
  --data-urlencode "dnsServers=$server_ip" \
  --data-urlencode blockLocallyAdministeredMacAddresses=false >/dev/null

scope="$(api /dhcp/scopes/get --data-urlencode "name=$scope_name" 2>/dev/null || true)"
while IFS=$'\t' read -r mac address host; do
  # The API answers hardware addresses with dashes, the scope set call
  # takes colons: normalise both sides before comparing.
  present="$(jq -r --arg mac "$mac" \
    '[(.response.reservedLeases // [])[]
      | select((((.hardwareAddress // "") | ascii_upcase) | gsub("-"; ":")) == ($mac | ascii_upcase))] | length' \
    <<<"$scope" 2>/dev/null || echo 0)"
  [ "$present" = "0" ] || continue
  apply /dhcp/scopes/addReservedLease \
    --data-urlencode "name=$scope_name" \
    --data-urlencode "hardwareAddress=$mac" \
    --data-urlencode "ipAddress=$address" \
    --data-urlencode "hostName=$host" >/dev/null
done < <(jq -r '.[] | [.hardwareAddress, .ipAddress, .hostName] | @tsv' <<<"$leases_json")

# Enabling an already-enabled scope is undocumented, so tolerate a
# rejection here and verify the end state through the scope list.
api /dhcp/scopes/enable --data-urlencode "name=$scope_name" >/dev/null 2>&1 || true
enabled="$(api /dhcp/scopes/list |
  jq -r --arg name "$scope_name" '[.response.scopes[] | select(.name == $name)][0].enabled // false')"
if [ "$enabled" != "true" ]; then
  echo "DHCP scope $scope_name is not enabled" >&2
  exit 1
fi

echo "converged: dns settings, $zone zone, dhcp scope $scope_name"

# --- Single sign-on (Authelia OIDC) -------------------------------------
# Last, because applying the SSO config restarts the web service. The
# API masks the client secret on read, so gate on a hash of the whole
# desired tuple instead of comparing the live config.
sso_secret="${TECHNITIUM_SSO_CLIENT_SECRET:-}"
if [ -z "$sso_secret" ]; then
  echo "TECHNITIUM_SSO_CLIENT_SECRET is missing; leaving SSO alone" >&2
else
  sso_hash="$(printf '%s' "$sso_authority|$sso_client_id|$sso_secret|$sso_scopes|$sso_group_map" |
    sha256sum | cut -d' ' -f1)"
  sso_hash_file=/var/lib/technitium-converge/sso.hash
  if [ ! -f "$sso_hash_file" ] || [ "$(<"$sso_hash_file")" != "$sso_hash" ]; then
    apply /admin/sso/set \
      --data-urlencode ssoEnabled=true \
      --data-urlencode "ssoAuthority=$sso_authority" \
      --data-urlencode "ssoClientId=$sso_client_id" \
      --data-urlencode "ssoClientSecret=$sso_secret" \
      --data-urlencode "ssoScopes=$sso_scopes" \
      --data-urlencode ssoAllowSignup=true \
      --data-urlencode ssoAllowSignupOnlyForMappedUsers=true \
      --data-urlencode "ssoGroupMap=$sso_group_map" >/dev/null
    echo "$sso_hash" >"$sso_hash_file"
    echo "applied SSO config"
  fi
fi
