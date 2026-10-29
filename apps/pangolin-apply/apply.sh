#!/usr/bin/env bash

set -euo pipefail

api="$PANGOLIN_API_URL"
org_id="$PANGOLIN_ORG_ID"
org_name="$PANGOLIN_ORG_NAME"
org_subnet="$PANGOLIN_ORG_SUBNET"
org_utility_subnet="$PANGOLIN_ORG_UTILITY_SUBNET"
oidc_issuer="$PANGOLIN_OIDC_ISSUER"
expected_redirect="$PANGOLIN_EXPECTED_REDIRECT"
sites="$PANGOLIN_SITES"

jar=$(mktemp)
trap 'rm -f "$jar"' EXIT

for _ in $(seq 1 60); do
  if curl -sf -o /dev/null "$api/"; then break; fi
  sleep 2
done
curl -sf -o /dev/null "$api/" || {
  echo "pangolin API not reachable" >&2
  exit 1
}

echo "logging in as $PANGOLIN_ADMIN_EMAIL"
curl -sf -c "$jar" -X POST "$api/auth/login" \
  -H 'Content-Type: application/json' \
  -H 'x-csrf-token: x-csrf-protection' \
  -d "$(jq -n --arg e "$PANGOLIN_ADMIN_EMAIL" \
    --arg p "$PANGOLIN_ADMIN_PASSWORD" \
    '{email: $e, password: $p}')" >/dev/null

code=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" \
  "$api/org/$org_id" || true)
if [ "$code" != "200" ]; then
  echo "creating org $org_id"
  curl -sf -b "$jar" -X PUT "$api/org" \
    -H 'Content-Type: application/json' \
    -H 'x-csrf-token: x-csrf-protection' \
    -d "$(jq -n \
      --arg orgId "$org_id" \
      --arg name "$org_name" \
      --arg subnet "$org_subnet" \
      --arg utilitySubnet "$org_utility_subnet" \
      '{orgId: $orgId, name: $name, subnet: $subnet,
        utilitySubnet: $utilitySubnet}')" >/dev/null
fi

# Pin niceId and newtId to the site key so the DB matches newt's --id.
mapfile -t site_list < <(jq -r 'keys[]' <<<"$sites")
for site in "${site_list[@]}"; do
  nice_id=$(jq -r --arg s "$site" '.[$s].niceId' <<<"$sites")
  secret_env=$(jq -r --arg s "$site" '.[$s].secretEnv' <<<"$sites")

  code=$(curl -s -o /dev/null -w '%{http_code}' -b "$jar" \
    "$api/org/$org_id/site/$nice_id" || true)
  if [ "$code" != "200" ]; then
    echo "creating site $nice_id"
    curl -sf -b "$jar" -X PUT "$api/org/$org_id/site" \
      -H 'Content-Type: application/json' \
      -H 'x-csrf-token: x-csrf-protection' \
      -d "$(jq -n \
        --arg name "$nice_id" \
        --arg niceId "$nice_id" \
        --arg newtId "$nice_id" \
        --arg secret "${!secret_env}" \
        '{name: $name, niceId: $niceId, newtId: $newtId,
          secret: $secret, type: "newt"}')" >/dev/null
  fi
done

# Authelia's `pangolin` client hardcodes the redirect URL (idpId 1 on a fresh DB).
if curl -sf -b "$jar" "$api/idp" |
  jq -e --arg n "$PANGOLIN_IDP_NAME" \
    '[.data.idps[]? | select(.name == $n)] | length > 0' >/dev/null; then
  echo "idp $PANGOLIN_IDP_NAME already registered"
else
  echo "registering idp $PANGOLIN_IDP_NAME"
  created=$(curl -sf -b "$jar" -X PUT "$api/idp/oidc" \
    -H 'Content-Type: application/json' \
    -H 'x-csrf-token: x-csrf-protection' \
    -d "$(jq -n \
      --arg name "$PANGOLIN_IDP_NAME" \
      --arg clientId "$PANGOLIN_IDP_CLIENT_ID" \
      --arg clientSecret "$PANGOLIN_IDP_CLIENT_SECRET" \
      --arg issuer "$oidc_issuer" \
      '{name: $name, clientId: $clientId,
        clientSecret: $clientSecret,
        authUrl: ($issuer + "/api/oidc/authorization"),
        tokenUrl: ($issuer + "/api/oidc/token"),
        identifierPath: "sub",
        emailPath: "email",
        namePath: "name",
        scopes: "openid profile email",
        autoProvision: true,
        variant: "oidc"}')")
  redirect=$(jq -r '.data.redirectUrl' <<<"$created")
  echo "registered idp $(jq -r '.data.idpId' <<<"$created"), redirect $redirect"
  if [ "$redirect" != "$expected_redirect" ]; then
    echo "WARNING: redirect $redirect != authelia redirect_uris $expected_redirect" >&2
  fi
fi
