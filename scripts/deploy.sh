#!/usr/bin/env bash

set -e

HOST=$1

if [ "$(hostname)" == "$HOST" ]; then
  sudo nixos-rebuild switch --flake "github:KuiprLab/sorbet.nix#$HOST" \
    --option extra-substituters 'https://install.determinate.systems' \
    --option trusted-substituters 'https://sorbet.cachix.org https://cache.nixos.org https://frostplexx.cachix.org https://nvf.cachix.org https://nix-community.cachix.org' \
    --option trusted-public-keys 'cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= frostplexx.cachix.org-1:kjkhnGNSkUvf5Mx8OEfhzaR830CUkDRglaKduAcr3UQ= nvf.cachix.org-1:GMQWiUhZ6ux9D5CvFFMwnc2nFrUHTeGaXRlVBXo+naI= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs= sorbet.cachix.org-1:p1+jtoj8v75vhRut7fGY5jL7k4BNMFvMBcQSDKbF3Aw=' \
    --option extra-trusted-public-keys cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM=
else
  # Deploy using deploy-rs
  echo "Deploying $HOST..."
  if [ -n "$HOST" ]; then
    echo "Deploying configuration: $HOST"
    # Nix flakes only read git-tracked files, so an uncommitted change would
    # be silently absent from the closure we are about to activate. Refuse
    # rather than auto-commit: history is how we bisect and revert the lab.
    if [ -n "$(git status --porcelain)" ]; then
      echo "error: working tree is dirty -- refusing to deploy." >&2
      echo "Flakes ignore uncommitted files, so this deploy would not contain your changes." >&2
      echo >&2
      git status --short >&2
      echo >&2
      echo "Commit (with a real message) and re-run: just deploy $HOST" >&2
      exit 1
    fi
    nix run nixpkgs#deploy-rs -- -s .#"$HOST"
  else
    echo "No configuration selected."
  fi
  echo "Deployment complete!"
fi
