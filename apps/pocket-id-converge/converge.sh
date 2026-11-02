#!/usr/bin/env bash

set -euo pipefail

api="$POCKET_ID_API_URL"
app="$POCKET_ID_APP_URL"
base="$POCKET_ID_BASE_URL"
desired="$POCKET_ID_CLIENTS_JSON"
desired_users="$POCKET_ID_USERS_JSON"

set -a
# shellcheck disable=SC1090,SC1091
. "$POCKET_ID_ENV_FILE"
set +a

ready=false
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 -o /dev/null "$base/healthz" 2>/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
if [ "$ready" != true ]; then
  echo "pocket-id is not reachable at $base" >&2
  exit 1
fi

# A malformed payload would otherwise skip a whole loop silently.
jq -e 'type == "object"' <<<"$desired" >/dev/null || {
  echo "POCKET_ID_CLIENTS_JSON is not a JSON object" >&2
  exit 1
}
jq -e 'type == "array"' <<<"$desired_users" >/dev/null || {
  echo "POCKET_ID_USERS_JSON is not a JSON array" >&2
  exit 1
}

request() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS --max-time 10 -X "$method" \
      -H "X-API-Key: $STATIC_API_KEY" \
      -H "Content-Type: application/json" \
      -d "$body" "$api$path"
  else
    curl -fsS --max-time 10 -X "$method" \
      -H "X-API-Key: $STATIC_API_KEY" \
      "$api$path"
  fi
}

# PUT replaces the whole client, so every field is rendered: an omitted bool silently flips to false.
render_client() {
  jq -c --arg id "$1" '{
      id: $id,
      name: .name,
      description: (.description // ""),
      callbackURLs: (.callbackURLs // []),
      logoutCallbackURLs: (.logoutCallbackURLs // []),
      backchannelLogoutURL: (.backchannelLogoutURL // ""),
      isPublic: (.isPublic // false),
      pkceEnabled: (.pkceEnabled // true),
      requiresReauthentication: (.requiresReauthentication // false),
      requiresPushedAuthorizationRequests: (.requiresPushedAuthorizationRequests // false),
      skipConsent: (.skipConsent // true),
      isGroupRestricted: (.isGroupRestricted // false),
      accessTokenDurationMinutes: (.accessTokenDurationMinutes // 0),
      refreshTokenDurationMinutes: (.refreshTokenDurationMinutes // 0),
      launchURL: (.launchURL // null),
      claimMappingPolicyId: (.claimMappingPolicyId // "")
    }'
}

for user in $(jq -c '.[]' <<<"$desired_users"); do
  user_id=$(jq -r '.id' <<<"$user")
  username=$(jq -r '.username' <<<"$user")
  payload=$(jq -c '{
      id: .id,
      username: .username,
      email: (.email // null),
      emailVerified: (.emailVerified // false),
      firstName: (.firstName // ""),
      lastName: (.lastName // ""),
      displayName: (.displayName // .username),
      isAdmin: (.isAdmin // false),
      disabled: (.disabled // false),
      locale: (.locale // null),
      userGroupIds: (.userGroupIds // [])
    }' <<<"$user")

  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "X-API-Key: $STATIC_API_KEY" "$api/users/$user_id")
  case "$status" in
  200)
    echo "updating user $username"
    request PUT "/users/$user_id" "$payload" >/dev/null
    ;;
  404)
    echo "creating user $username"
    request POST "/users" "$payload" >/dev/null
    ;;
  *)
    echo "unexpected status $status for user $username" >&2
    exit 1
    ;;
  esac

  # A user without a passkey cannot sign in, and only the holder can enrol one.
  credentials=$(request GET "/users/$user_id/webauthn-credentials" | jq 'length')
  if [ "$credentials" -eq 0 ]; then
    code=$(request POST "/users/$user_id/one-time-access-token" '{"ttl":"24h"}' | jq -r .token)
    echo "$username has no passkey; enrol one within 24h: $app/lc/$code"
  fi
done

for client_id in $(jq -r 'keys[]' <<<"$desired"); do
  client=$(jq -c --arg id "$client_id" '.[$id]' <<<"$desired")
  secret_env=$(jq -r '.secretEnv' <<<"$client")
  payload=$(render_client "$client_id" <<<"$client")

  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -H "X-API-Key: $STATIC_API_KEY" "$api/oidc/clients/$client_id")
  case "$status" in
  200)
    echo "updating oidc client $client_id"
    request PUT "/oidc/clients/$client_id" "$payload" >/dev/null
    ;;
  404)
    echo "creating oidc client $client_id"
    request POST "/oidc/clients" "$payload" >/dev/null
    ;;
  *)
    echo "unexpected status $status for oidc client $client_id" >&2
    exit 1
    ;;
  esac

  secret_value="${!secret_env:-}"
  if [ -z "$secret_value" ]; then
    echo "$secret_env is missing from $POCKET_ID_ENV_FILE" >&2
    exit 1
  fi

  # Values cannot be read back, so an existing secret is left alone; rotation is delete + re-run.
  count=$(request GET "/oidc/clients/$client_id/secrets" | jq 'length')
  case "$count" in
  0)
    echo "creating client secret for $client_id"
    request POST "/oidc/clients/$client_id/secrets" \
      "$(jq -nc --arg secret "$secret_value" '{secret: $secret}')" >/dev/null
    ;;
  1) ;;
  *)
    echo "oidc client $client_id has $count secrets; delete the extras by hand" >&2
    exit 1
    ;;
  esac
done
