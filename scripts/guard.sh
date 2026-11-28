#!/usr/bin/env bash
# Block a destructive recipe against a production host unless it is opted in.

set -euo pipefail

target="${1:?usage: guard.sh <target> <action>}"
action="${2:?usage: guard.sh <target> <action>}"

case "$target" in
sorbet | eclair | crossaint | *sorbet* | *eclair* | *crossaint*)
  if [[ "${HOMELAB_ALLOW_PROD:-0}" != "1" ]]; then
    echo "refusing to $action $target: production host" >&2
    echo "re-run with HOMELAB_ALLOW_PROD=1 if you mean it" >&2
    exit 1
  fi
  ;;
esac
