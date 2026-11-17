#!/usr/bin/env bash
set -euo pipefail

base="${DN_BASE_URL:?}"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

log() { printf '%s\n' "$*"; }

# call METHOD PATH [BODY] -> response body on stdout; exits with the server's
# own error body when the status is not 2xx, so the journal says what is wrong.
call() {
  local method=$1 path=$2 body=${3:-} status
  local args=(-sS -o "$tmpdir/body" -w '%{http_code}' -X "$method")
  [ -n "${token:-}" ] && args+=(-H "Authorization: Bearer $token")
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")

  status=$(curl "${args[@]}" "$base$path") || {
    echo "curl could not reach $base$path" >&2
    exit 1
  }
  if [ "${status:0:1}" != "2" ]; then
    echo "$method $path -> HTTP $status" >&2
    cat "$tmpdir/body" >&2
    echo >&2
    [ -n "${hint:-}" ] && printf '%s\n' "$hint" >&2
    exit 1
  fi
  cat "$tmpdir/body"
}

for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null --max-time 5 "$base/health"; then break; fi
  sleep 2
done
curl -fsS -o /dev/null --max-time 5 "$base/health" || {
  echo "droppedneedle not reachable at $base" >&2
  exit 1
}

credentials=$(jq -n --arg u "$DN_ADMIN_USER" --arg p "$DN_ADMIN_PASSWORD" \
  '{username: $u, password: $p, transport: "bearer"}')

if [ "$(call GET /api/v3/auth/setup/status | jq -r .setup_required)" = "true" ]; then
  token=$(call POST /api/v3/auth/setup "$credentials" | jq -r .token)
  log "created admin $DN_ADMIN_USER"
else
  hint="an admin already exists: put its password in DN_ADMIN_PASSWORD, or stop the container and remove
/var/lib/droppedneedle/cache/library.db* so converge can create the account itself"
  token=$(call POST /api/v3/auth/login "$credentials" | jq -r .token)
  hint=""
fi
[ -n "$token" ] && [ "$token" != "null" ] || {
  echo "no session token for $DN_ADMIN_USER" >&2
  exit 1
}

call PUT /api/v3/settings/musicbrainz "$(jq -n \
  --arg source "$DN_MB_SOURCE" --argjson rate "$DN_MB_RATE_LIMIT" \
  '{source_mode: $source, rate_limit: $rate}')" >/dev/null
log "musicbrainz: $DN_MB_SOURCE"

library=$(call GET /api/v3/settings/library)
if jq -e --arg p "$DN_LIBRARY_PATH" 'any(.library_roots[]?; .path == $p)' <<<"$library" >/dev/null; then
  log "library: $DN_LIBRARY_PATH already a root"
else
  call PUT /api/v3/settings/library "$(jq -n \
    --arg rev "$(jq -r .policy_revision <<<"$library")" \
    --arg path "$DN_LIBRARY_PATH" --arg id "$DN_LIBRARY_ROOT_ID" \
    '{expected_policy_revision: $rev,
      settings: {
        enabled: true,
        library_roots: [{id: $id, label: "music", path: $path, policy: "automatic", rules: []}]
      }}')" >/dev/null
  log "library: added root $DN_LIBRARY_PATH"
fi

call PUT /api/v3/settings/download-client/config "$(jq -n \
  --arg url "$DN_SLSKD_URL" --arg key "$DN_SLSKD_API_KEY" \
  '{enabled: true, url: $url, api_key: $key}')" >/dev/null
log "slskd: $DN_SLSKD_URL"

call PUT /api/v3/settings/navidrome "$(jq -n \
  --arg url "$DN_NAVIDROME_URL" --arg user "$DN_NAVIDROME_USER" \
  --arg password "$DN_NAVIDROME_PASSWORD" --arg path "$DN_NAVIDROME_PLAYLIST_PATH" \
  '{enabled: true, navidrome_url: $url, username: $user, password: $password,
    playlist_sync_enabled: true, playlist_sync_path: $path, playlist_sync_scope: "public"}')" >/dev/null
log "navidrome: $DN_NAVIDROME_URL"

call PUT /api/v3/settings/oidc "$(jq -n \
  --arg issuer "$DN_OIDC_ISSUER" --arg clientId "$DN_OIDC_CLIENT_ID" \
  --arg secret "$DN_OIDC_CLIENT_SECRET" --arg redirect "$DN_OIDC_REDIRECT_URI" \
  --arg scopes "$DN_OIDC_SCOPES" \
  '{enabled: true, issuer: $issuer, client_id: $clientId, client_secret: $secret,
    redirect_uri: $redirect, scopes: $scopes}')" >/dev/null
log "oidc: $DN_OIDC_ISSUER"

call PUT /api/v3/settings/security "$(jq -n \
  '{hibp_check: true, hsts_max_age: 31536000, hsts_include_subdomains: true}')" >/dev/null
log "security: hibp and hsts"

call POST /api/v3/auth/logout >/dev/null
log "converged"
