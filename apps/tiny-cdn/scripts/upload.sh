#!/usr/bin/env bash
# Signed client for tiny-cdn. The protocol is documented in ../README.md.
set -euo pipefail

BASE_URL="${BASE_URL:-http://127.0.0.1:3030}"
# Public key; the private half is used through ssh-agent.
KEY="${KEY:-$HOME/.ssh/id_ed25519.pub}"

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
  request PUT "/upload/$(basename "$file")" "$file" "${3:-}"
  ;;
list)
  request GET /list /dev/null
  ;;
delete)
  request DELETE "/${2:?missing uuid}" /dev/null
  ;;
get)
  curl -fsS "$BASE_URL/${2:?missing uuid}"
  ;;
*)
  usage
  ;;
esac
