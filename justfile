config := "sorbet"

default:
    just --list


random-string:
    @cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 50 | head -n 1

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
    caches=$(nix-instantiate --eval --strict --json modules/flake/_caches.nix)
    substituters=$(jq -r '.substituters | join(" ")' <<<"$caches")
    public_keys=$(jq -r '.trustedPublicKeys | join(" ")' <<<"$caches")
    nix run github:nix-community/nixos-anywhere -- --flake .#{{config}} \
      --env-password \
      --option substituters "$substituters" \
      --option extra-substituters 'https://install.determinate.systems' \
      --option trusted-substituters "$substituters" \
      --option trusted-public-keys "$public_keys" \
      --option extra-trusted-public-keys cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM= \
      --target-host {{target}}

# Trigger a comin deployment on one host (sorbet or eclair)
deploy host:
    @ssh {{host}} comin fetch

# Deploy the local working tree to one host, bypassing comin (mode: test|switch)
deploy-local host mode="test":
    nix run nixpkgs#nixos-rebuild -- {{mode}} \
      --flake .#{{host}} \
      --build-host root@sorbet \
      --target-host root@{{host}}

deploy-status host="":
    #!/usr/bin/env bash
    if [[ -z "{{host}}" ]]; then
        ssh sorbet comin status
        echo ------------------
        ssh eclair comin status
    else
        ssh {{host}} comin status
    fi


# Push config to testing branch
test host="sorbet":
    @git fetch origin main
    @git rebase --gpg-sign origin/main     # re-signs the rebased commits
    @git push origin HEAD:testing-{{host}} --force


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
