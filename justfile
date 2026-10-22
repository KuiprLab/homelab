config := "sorbet"

default:
    just --list

# Build the NixOS config locally (requires a Linux builder on macOS)
build: fmt check
    @git add .
    @nix build ".#nixosConfigurations.sorbet.config.system.build.toplevel" --system x86_64-linux

# Deploy to the server via rsync + SSH
[doc("Deploy the NixOS configuration to the server using nixos-anywhere")]
install target:
    #!/usr/bin/env bash
    set -euxo pipefail
    read -s -p "Enter SSH password for {{target}}: " SSHPASS
    echo
    export SSHPASS
    nix run github:nix-community/nixos-anywhere -- --flake .#{{config}} \
      --env-password \
      --option substituters 'https://sorbet.cachix.org https://cache.nixos.org https://frostplexx.cachix.org https://nvf.cachix.org https://nix-community.cachix.org' \
      --option extra-substituters 'https://install.determinate.systems' \
      --option trusted-substituters 'https://sorbet.cachix.org https://cache.nixos.org https://frostplexx.cachix.org https://nvf.cachix.org https://nix-community.cachix.org' \
      --option trusted-public-keys 'cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY= frostplexx.cachix.org-1:kjkhnGNSkUvf5Mx8OEfhzaR830CUkDRglaKduAcr3UQ= nvf.cachix.org-1:GMQWiUhZ6ux9D5CvFFMwnc2nFrUHTeGaXRlVBXo+naI= nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs= sorbet.cachix.org-1:p1+jtoj8v75vhRut7fGY5jL7k4BNMFvMBcQSDKbF3Aw=' \
      --option extra-trusted-public-keys cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM= \
      --target-host {{target}}

# Format all Nix files
fmt:
    nix fmt .

# Run flake checks
check: fmt
    nix flake check --all-systems


upload-secrets host:
    @./scripts/upload-secrets.sh {{host}}

# Run a beet command on sorbet as daniel (e.g. `just beet import ~/Downloads/album`)
beet *args:
    ssh daniel@192.168.0.85 beet {{args}}


update-inputs:
    @NIX_CONFIG="access-tokens = github.com=$(gh auth token)" nix flake update
