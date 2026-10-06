#!/usr/bin/env bash

set -e

# Stream the master age key from 1Password to the target host over stdin —
# never via an ssh command-line argument (argv is world-readable in /proc and
# lands in the remote shell's history). Same pattern as documented in the
# README. Do not add StrictHostKeyChecking=no: the first connect should pin
# the host key interactively.
op read "$(nix run nixpkgs#yq -- -r '.onepassworditem' .sops.yaml)" |
  ssh root@"$1" "mkdir -p /var/lib/sops && cat > /var/lib/sops/age-key.txt && chmod 400 /var/lib/sops/age-key.txt"
