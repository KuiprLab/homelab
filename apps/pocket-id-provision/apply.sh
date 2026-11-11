#!/usr/bin/env bash

set -euo pipefail

api="$POCKET_ID_API_URL"
clients_file="$POCKET_ID_CLIENTS_FILE"

for _ in $(seq 1 60); do
  if curl -fsS -o /dev/null --max-time 5 "$api/healthz"; then
    break
  fi
  sleep 2
done
curl -fsS -o /dev/null --max-time 5 "$api/healthz" || {
  echo "pocket id not reachable at $api" >&2
  exit 1
}

set -a
# shellcheck disable=SC1090,SC1091
. "$POCKET_ID_ENV_FILE"
set +a

if [ -z "${STATIC_API_KEY:-}" ]; then
  echo "STATIC_API_KEY missing from $POCKET_ID_ENV_FILE" >&2
  exit 1
fi

api_call() {
  curl -fsS --max-time 15 -H "X-API-Key: $STATIC_API_KEY" \
    -H 'Content-Type: application/json' "$@"
}

status() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
    -H "X-API-Key: $STATIC_API_KEY" "$1"
}

mapfile -t client_ids < <(jq -r 'keys[]' "$clients_file")
if [ "${#client_ids[@]}" -eq 0 ]; then
  echo "no clients declared in $clients_file" >&2
  exit 1
fi

for client_id in "${client_ids[@]}"; do
  payload=$(jq -c --arg id "$client_id" '.[$id] | del(.secret)' "$clients_file")
  declared_secret=$(jq -r --arg id "$client_id" '.[$id].secret // empty' "$clients_file")

  case "$(status "$api/api/oidc/clients/$client_id")" in
  200)
    api_call -X PUT "$api/api/oidc/clients/$client_id" -d "$payload" >/dev/null
    echo "updated client $client_id"
    ;;
  404)
    api_call -X POST "$api/api/oidc/clients" \
      -d "$(jq -c --arg id "$client_id" '. + {id: $id}' <<<"$payload")" >/dev/null
    echo "created client $client_id"
    ;;
  *)
    echo "unexpected status reading client $client_id" >&2
    exit 1
    ;;
  esac

  if [ -z "$declared_secret" ]; then
    echo "no secret declared for client $client_id" >&2
    continue
  fi

  # Only the first four characters of an active secret are readable, so a match on them is the whole check.
  have_declared_secret=false
  undeclared_secret_ids=()
  secrets=$(api_call "$api/api/oidc/clients/$client_id/secrets")
  while IFS=$'\t' read -r secret_id prefix; do
    if [ -n "$prefix" ] && [[ $declared_secret == "$prefix"* ]]; then
      have_declared_secret=true
    else
      undeclared_secret_ids+=("$secret_id")
    fi
  done < <(jq -r '.[] | select(.isActive) | [.id, .prefix] | @tsv' <<<"$secrets")

  if [ "$have_declared_secret" = false ]; then
    api_call -X POST "$api/api/oidc/clients/$client_id/secrets" \
      -d "$(jq -n --arg secret "$declared_secret" '{secret: $secret}')" >/dev/null
    echo "created declared secret for client $client_id"
  fi

  for secret_id in "${undeclared_secret_ids[@]}"; do
    api_call -X DELETE "$api/api/oidc/clients/$client_id/secrets/$secret_id" >/dev/null
    echo "deleted undeclared secret $secret_id for client $client_id"
  done
done
