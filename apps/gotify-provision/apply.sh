#!/usr/bin/env bash
# Reconcile Gotify applications, tokens and icons.
#
# Gotify has no declarative app/token config; applications are SQLite rows.
# This unit creates the applications declared in GOTIFY_APPS_JSON and writes
# their tokens to its state dir. Tokens never enter git.
#
# Icons are names from selfh.st/icons (or full URLs) in Nix. Gotify only
# accepts an uploaded image, not an icon URL, so the reconciler resolves the
# name to https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/<name>.png and
# POSTs it to /application/<id>/image. A reference file and a hash prevent a
# re-upload on every run. Supported formats: PNG, JPEG, GIF. Gotify does not
# accept SVG or WebP.
#
# The reconciler authenticates with HTTP Basic auth, so the Gotify container
# keeps GOTIFY_LOCALAUTH_ENABLED=true. The web UI still uses OIDC because
# GOTIFY_OIDC_AUTO_REDIRECT is set. There are two local users:
#
#   admin  -- sops password, used only to create/update the provision user.
#   daniel -- sops password, owns the applications. It is the same username
#             as the Authelia user, and GOTIFY_OIDC_LINK_BY_USERNAME=true
#             links the OIDC identity to it. The iOS client token is therefore
#             owned by the same user as the applications.
#
# A failed run exits 0: a missing Gotify must not abort a deployment. The
# timer retries every five minutes.
#
# The desired state arrives as environment variables from the unit (see
# _module.nix); this file carries none of its own.

set -euo pipefail

base="$GOTIFY_BASE_URL"
token_dir=/var/lib/gotify-provision
apps_json_desired="$GOTIFY_APPS_JSON"
user_name="$GOTIFY_USER_NAME"

# Wait for Gotify. A missing server is a retry, not a failure.
ready=false
for _ in $(seq 1 60); do
  if curl -fsS --max-time 5 "$base/health" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if [ "$ready" != true ]; then
  echo "gotify not reachable at $base; retrying on the next timer run" >&2
  exit 0
fi

set -a
# shellcheck disable=SC1090,SC1091
. "$GOTIFY_ADMIN_ENV_FILE"
set +a

admin_pass="$GOTIFY_DEFAULTUSER_PASS"
user_pass="$GOTIFY_PROVISION_USER_PASS"

admin_api() {
  curl -fsS --max-time 15 -u "admin:$admin_pass" \
    -H 'Content-Type: application/json' "$@"
}

user_api() {
  curl -fsS --max-time 15 -u "$user_name:$user_pass" \
    -H 'Content-Type: application/json' "$@"
}

user_upload() {
  curl -fsS --max-time 30 -u "$user_name:$user_pass" "$@"
}

# Ensure the local provision user exists and has the sops password.
# If the OIDC login auto-registered the user first, this adds a local
# password to that same row instead of creating a duplicate.
users=$(admin_api "$base/user" 2>/dev/null || true)
if [ -z "$users" ]; then
  echo "could not list gotify users; retrying on the next timer run" >&2
  exit 0
fi
user_id=$(printf '%s' "$users" | jq -r --arg n "$user_name" '.[] | select(.name == $n) | .id' | head -n1)
if [ -z "$user_id" ]; then
  admin_api -X POST "$base/user" \
    -d "$(jq -n --arg n "$user_name" --arg p "$user_pass" '{name: $n, pass: $p, admin: true}')" \
    >/dev/null 2>&1 || true
else
  admin_api -X POST "$base/user/$user_id" \
    -d "$(jq -n --arg n "$user_name" --arg p "$user_pass" '{name: $n, pass: $p, admin: true}')" \
    >/dev/null 2>&1 || true
fi

apps_json=$(user_api "$base/application" 2>/dev/null || true)
if [ -z "$apps_json" ]; then
  echo "could not list gotify applications as $user_name; retrying on the next timer run" >&2
  exit 0
fi

mapfile -t apps < <(jq -r 'keys[]' <<<"$apps_json_desired")
for app in "${apps[@]}"; do
  token_file="$token_dir/$app.token"
  icon_ref=$(jq -r --arg n "$app" '.[$n].icon // empty' <<<"$apps_json_desired")
  id=$(printf '%s' "$apps_json" | jq -r --arg n "$app" '.[] | select(.name == $n) | .id' | head -n1)

  if [ -n "$id" ] && [ -s "$token_file" ]; then
    echo "gotify app $app already provisioned"
  else
    token=""
    if [ -n "$id" ]; then
      token=$(user_api -X PUT "$base/application/$id/security" \
        -d '{"regenerateToken":true}' 2>/dev/null |
        jq -r '.regenerateToken.token // empty' 2>/dev/null || true)
    else
      response=$(user_api -X POST "$base/application" \
        -d "$(jq -n --arg n "$app" '{name: $n}')" 2>/dev/null || true)
      token=$(printf '%s' "$response" | jq -r '.token // empty' 2>/dev/null || true)
      id=$(printf '%s' "$response" | jq -r '.id // empty' 2>/dev/null || true)
    fi

    if [ -z "$token" ]; then
      echo "could not provision gotify app $app" >&2
      continue
    fi

    install -m 0400 /dev/null "$token_file"
    printf '%s' "$token" >"$token_file"
    echo "provisioned gotify app $app"

    if [ "$app" = "beets" ]; then
      install -m 0400 /dev/null "$token_dir/beets.env"
      printf 'GOTIFY_TOKEN=%s\n' "$token" >"$token_dir/beets.env"
    fi
  fi

  if [ -n "$icon_ref" ] && [ -n "$id" ]; then
    case "$icon_ref" in
    http://* | https://*) icon_url="$icon_ref" ;;
    *) icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/$icon_ref.png" ;;
    esac
    icon_file="$token_dir/$app.icon"
    hash_file="$token_dir/$app.icon.sha256"
    ref_file="$token_dir/$app.icon.ref"
    current_image=$(printf '%s' "$apps_json" | jq -r --arg n "$app" '.[] | select(.name == $n) | .image' | head -n1)
    old_ref=$(cat "$ref_file" 2>/dev/null || true)

    # Skip the download when the app already has a custom image and
    # the configured icon reference did not change. This avoids
    # hammering the icon CDN every five minutes.
    if [ "$current_image" != "static/defaultapp.png" ] && [ "$icon_ref" = "$old_ref" ] && [ -s "$hash_file" ]; then
      :
    elif curl -fsSL --max-time 20 "$icon_url" -o "$icon_file"; then
      hash=$(sha256sum "$icon_file" | cut -d' ' -f1)
      if user_upload -X POST "$base/application/$id/image" \
        -F "file=@$icon_file;filename=icon.png" >/dev/null 2>&1; then
        install -m 0400 /dev/null "$hash_file"
        printf '%s' "$hash" >"$hash_file"
        install -m 0400 /dev/null "$ref_file"
        printf '%s' "$icon_ref" >"$ref_file"
        echo "uploaded icon for $app"
      else
        echo "could not upload icon for $app" >&2
      fi
    else
      echo "could not download icon for $app" >&2
    fi
  fi
done
