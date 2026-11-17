#!/usr/bin/env bash
set -euo pipefail

base="${DN_BASE_URL:?}"
log() { printf '%s\n' "$*"; }

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

if [ "$(curl -fsS "$base/api/v3/auth/setup/status" | jq -r .setup_required)" = "true" ]; then
  token=$(curl -fsS -X POST -H 'Content-Type: application/json' -d "$credentials" \
    "$base/api/v3/auth/setup" | jq -r .token)
  log "created admin $DN_ADMIN_USER"
else
  token=$(curl -fsS -X POST -H 'Content-Type: application/json' -d "$credentials" \
    "$base/api/v3/auth/login" | jq -r .token)
fi
[ -n "$token" ] && [ "$token" != "null" ] || {
  echo "no session token for $DN_ADMIN_USER" >&2
  exit 1
}

api() { curl -fsS -H "Authorization: Bearer $token" -H 'Content-Type: application/json' "$@"; }

api -X PUT "$base/api/v3/settings/musicbrainz" -d "$(jq -n \
  --arg source "$DN_MB_SOURCE" --argjson rate "$DN_MB_RATE_LIMIT" \
  '{source_mode: $source, rate_limit: $rate}')" >/dev/null
log "musicbrainz: $DN_MB_SOURCE"

library=$(api "$base/api/v3/settings/library")
if jq -e --arg p "$DN_LIBRARY_PATH" 'any(.library_roots[]?; .path == $p)' <<<"$library" >/dev/null; then
  log "library: $DN_LIBRARY_PATH already a root"
else
  api -X PUT "$base/api/v3/settings/library" -d "$(jq -n \
    --arg rev "$(jq -r .policy_revision <<<"$library")" \
    --arg path "$DN_LIBRARY_PATH" \
    '{expected_policy_revision: $rev,
      settings: {
        enabled: true,
        library_roots: [{label: "music", path: $path, policy: "automatic", rules: []}]
      }}')" >/dev/null
  log "library: added root $DN_LIBRARY_PATH"
fi

api -X PUT "$base/api/v3/settings/download-client/config" -d "$(jq -n \
  --arg url "$DN_SLSKD_URL" --arg key "$DN_SLSKD_API_KEY" \
  '{enabled: true, url: $url, api_key: $key}')" >/dev/null
log "slskd: $DN_SLSKD_URL"

api -X PUT "$base/api/v3/settings/navidrome" -d "$(jq -n \
  --arg url "$DN_NAVIDROME_URL" --arg user "$DN_NAVIDROME_USER" \
  --arg password "$DN_NAVIDROME_PASSWORD" --arg path "$DN_NAVIDROME_PLAYLIST_PATH" \
  '{enabled: true, navidrome_url: $url, username: $user, password: $password,
    playlist_sync_enabled: true, playlist_sync_path: $path, playlist_sync_scope: "public"}')" >/dev/null
log "navidrome: $DN_NAVIDROME_URL"

api -X PUT "$base/api/v3/settings/oidc" -d "$(jq -n \
  --arg issuer "$DN_OIDC_ISSUER" --arg id "$DN_OIDC_CLIENT_ID" \
  --arg secret "$DN_OIDC_CLIENT_SECRET" --arg redirect "$DN_OIDC_REDIRECT_URI" \
  --arg scopes "$DN_OIDC_SCOPES" \
  '{enabled: true, issuer: $issuer, client_id: $id, client_secret: $secret,
    redirect_uri: $redirect, scopes: $scopes}')" >/dev/null
log "oidc: $DN_OIDC_ISSUER"

api -X PUT "$base/api/v3/settings/security" -d "$(jq -n \
  '{hibp_check: true, hsts_max_age: 31536000, hsts_include_subdomains: true}')" >/dev/null
log "security: hibp and hsts"

api -X POST "$base/api/v3/auth/logout" >/dev/null
log "converged"
