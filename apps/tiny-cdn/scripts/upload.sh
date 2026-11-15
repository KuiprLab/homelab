#!/usr/bin/env bash
# Signed client for tiny-cdn. The protocol is documented in ../README.md.
set -euo pipefail

APP_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BASE_URL="${BASE_URL:-http://127.0.0.1:3030}"
# Test key by default; override with KEY=~/.ssh/cdn.pub for the deployed instance.
KEY="${KEY:-$APP_DIR/tmp/SSH Key.pub}"

usage() {
  cat <<'EOF'
usage: upload.sh upload <file> [ttl-seconds]
       upload.sh list
       upload.sh delete <uuid>
       upload.sh get <uuid>
EOF
  exit 2
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

format_time() {
  if date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z' >/dev/null 2>&1; then
    date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z'
  else
    date -r "$1" '+%Y-%m-%d %H:%M:%S %Z'
  fi
}

sign() {
  local method=$1 path=$2 ts=$3 nonce=$4 hash=$5 expire=$6
  local message
  message=$(printf '%s\n%s\n%s\n%s\n%s\n%s' "$method" "$path" "$ts" "$nonce" "$hash" "$expire")
  printf '%s' "$message" |
    ssh-keygen -Y sign -f "$KEY" -n cdn-upload - 2>/dev/null |
    base64 | tr -d '\n'
}

request() {
  local method=$1 path=$2 file=$3 expire=${4:-}
  local ts nonce hash signature
  ts=$(date +%s)
  nonce=$(openssl rand -hex 16)
  hash=$(sha256_of "$file")
  signature=$(sign "$method" "$path" "$ts" "$nonce" "$hash" "${expire:--}")

  local headers=(
    -H "X-Timestamp: $ts"
    -H "X-Nonce: $nonce"
    -H "X-Content-SHA256: $hash"
    -H "X-Signature: $signature"
  )
  if [[ -n $expire ]]; then
    headers+=(-H "X-Expire-Seconds: $expire")
  fi

  curl -fsS -X "$method" "$BASE_URL$path" "${headers[@]}" --data-binary "@$file"
}

case "${1:-}" in
upload)
  file=${2:?missing file}
  name=$(jq -rn --arg n "$(basename "$file")" '$n|@uri')
  response=$(request PUT "/upload/$name" "$file" "${3:-}")
  id=$(jq -r '.id' <<<"$response")
  expires_at=$(jq -r '.expires_at' <<<"$response")
  printf '%s/%s/%s\n' "https://macbook-m4-pro.tailb368a.ts.net" "$id" "$name"
  printf 'expires %s\n' "$(format_time "$expires_at")"
  ;;
list)
  request GET /list /dev/null
  ;;
delete)
  request DELETE "/${2:?missing uuid}" /dev/null
  ;;
get)
  curl -fsS "$BASE_URL/raw/${2:?missing uuid}"
  ;;
*)
  usage
  ;;
esac
