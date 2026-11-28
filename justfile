devHost := "192.168.139.139"
devMachine := "nixos"

[private]
default:
    just --list

[group('misc')]
random-string:
    @cat /dev/urandom | LC_ALL=C tr -dc 'a-zA-Z0-9' | fold -w 50 | head -n 1

# Install NixOS on a blank machine with nixos-anywhere. Wipes the target disk.
[group('system')]
install host:
    #!/usr/bin/env bash
    set -euxo pipefail
    ./scripts/guard.sh "{{host}}" "install NixOS on"
    read -s -p "Enter SSH password for {{host}}: " SSHPASS
    echo
    export SSHPASS
    caches=$(nix-instantiate --eval --strict --json modules/flake/_caches.nix)
    substituters=$(jq -r '.substituters | join(" ")' <<<"$caches")
    public_keys=$(jq -r '.trustedPublicKeys | join(" ")' <<<"$caches")
    nix run github:nix-community/nixos-anywhere -- --flake .#{{host}} \
      --env-password \
      --option substituters "$substituters" \
      --option extra-substituters 'https://install.determinate.systems' \
      --option trusted-substituters "$substituters" \
      --option trusted-public-keys "$public_keys" \
      --option extra-trusted-public-keys cache.flakehub.com-3:hJuILl5sVK4iKm86JzgdXW12Y2Hwd5G07qKtHTOcDCM= \
      --target-host root@{{host}}

# Activate the sorbet config on the OrbStack machine (nix runs inside the machine)
[group('dev')]
deploy-dev:
    #!/usr/bin/env bash
    set -eu
    ./scripts/guard.sh "{{devHost}}" "deploy to"
    exec orb -m {{devMachine}} sudo nixos-rebuild switch --flake "{{justfile_directory()}}#sorbet-dev"

# Write the dev cluster kubeconfig to ~/.kube/sorbet-dev.yaml
[group('dev')]
kubeconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "$HOME/.kube"
    dest="$HOME/.kube/sorbet-dev.yaml"
    orb -m {{devMachine}} -u root cat /etc/rancher/k3s/k3s.yaml |
      sed -e "s|https://127.0.0.1:6443|https://{{devHost}}:6443|" \
          -e "s|default|sorbet-dev|g" > "$dest"
    chmod 600 "$dest"
    echo "$dest"

# Trigger a comin deployment on one host (sorbet, eclair or crossaint)
[group('comin')]
deploy host:
    @ssh {{host}} comin fetch

# Activate the local working tree on one host, bypassing comin (mode: test|switch)
[group('system')]
deploy-local host mode="test":
    #!/usr/bin/env bash
    set -eu
    if [[ "{{mode}}" != "test" ]]; then
      ./scripts/guard.sh "{{host}}" "switch"
    fi
    exec nix run nixpkgs#nixos-rebuild -- {{mode}} \
      --flake .#{{host}} \
      --build-host root@sorbet \
      --target-host root@{{host}}

[group('comin')]
deploy-status host="":
    #!/usr/bin/env bash
    if [[ -z "{{host}}" ]]; then
        ssh sorbet comin status
        echo ------------------
        ssh eclair comin status
    else
        ssh {{host}} comin status
    fi


# Push config to the testing branch of one host
[group('comin')]
test host="sorbet":
    #!/usr/bin/env bash
    set -eu
    git fetch origin main
    git rebase --gpg-sign origin/main     # comin rejects unsigned commits
    git push origin HEAD:testing-{{host}} --force


# Format all Nix files
[group('misc')]
[private]
fmt:
    nix fmt .

# Run flake checks
[group('misc')]
check: fmt
    nix flake check --all-systems


# Write the sops age key to a host; overwrites it, so old secrets stop decrypting.
[group('system')]
upload-secrets host:
    #!/usr/bin/env bash
    set -eu
    ./scripts/guard.sh "{{host}}" "replace the sops age key on"
    exec ./scripts/upload-secrets.sh "{{host}}"


[group('misc')]
update-inputs:
    @NIX_CONFIG="access-tokens = github.com=$(gh auth token)" nix flake update
