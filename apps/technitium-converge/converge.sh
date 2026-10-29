#!/usr/bin/env bash

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

# Do not log in while waiting: five failed logins block the client for 300s.
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
  # State dir from before DNS_SERVER_ADMIN_PASSWORD: admin/admin still works once.
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

set_args=()
while IFS=$'\t' read -r key value; do
  set_args+=(--data-urlencode "$key=$value")
done < <(jq -r 'to_entries[] | [.key, (.value | tostring)] | @tsv' <<<"$settings_json")

before="$(api /settings/get | jq -r '(.response.blockListUrls // []) | join(",")')"
updated="$(apply /settings/set "${set_args[@]}")"
after="$(jq -r '(.response.blockListUrls // []) | join(",")' <<<"$updated")"

if [ "$after" != "$before" ]; then
  apply /settings/forceUpdateBlockLists >/dev/null
fi

# An existing zone makes this call fail, which is the steady state.
api /zones/create \
  --data-urlencode "zone=$zone" \
  --data-urlencode type=Primary >/dev/null 2>&1 || true

# overwrite=true assigns the record set instead of appending a second A record.
for domain in "$zone" "*.$zone"; do
  apply /zones/records/add \
    --data-urlencode "zone=$zone" \
    --data-urlencode "domain=$domain" \
    --data-urlencode type=A \
    --data-urlencode "ipAddress=$server_ip" \
    --data-urlencode ttl=300 \
    --data-urlencode overwrite=true >/dev/null
done

# A fresh state dir ships a `Default` scope (192.168.1.0/24); drop it.
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
  # The API answers dash-separated MACs, the scope set call wants colons.
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

# Enabling an already-enabled scope is undocumented: tolerate the rejection.
api /dhcp/scopes/enable --data-urlencode "name=$scope_name" >/dev/null 2>&1 || true
enabled="$(api /dhcp/scopes/list |
  jq -r --arg name "$scope_name" '[.response.scopes[] | select(.name == $name)][0].enabled // false')"
if [ "$enabled" != "true" ]; then
  echo "DHCP scope $scope_name is not enabled" >&2
  exit 1
fi

echo "converged: dns settings, $zone zone, dhcp scope $scope_name"

# Last: applying SSO restarts the web service; the API masks the secret, so hash it.
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
