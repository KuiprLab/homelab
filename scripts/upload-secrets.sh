#!/usr/bin/env bash

set -e

# stdin, never argv (/proc and remote shell history); do not add StrictHostKeyChecking=no.
op read "$(nix run nixpkgs#yq -- -r '.onepassworditem' .sops.yaml)" |
  ssh root@"$1" "mkdir -p /var/lib/sops && cat > /var/lib/sops/age-key.txt && chmod 400 /var/lib/sops/age-key.txt"
