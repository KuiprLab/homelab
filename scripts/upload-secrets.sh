#!/usr/bin/env bash

set -e

AGE_KEY=$(op read "$(nix run nixpkgs#yq -- -r '.onepassworditem' .sops.yaml)")

# Write the AGE_KEY into /var/lib/sops/age-key.txt on the remote server
ssh -o "StrictHostKeyChecking=no" root@"$1" "mkdir -p /var/lib/sops && echo '$AGE_KEY' > /var/lib/sops/age-key.txt && chmod 600 /var/lib/sops/age-key.txt"
