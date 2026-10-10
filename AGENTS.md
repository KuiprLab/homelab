This is the monorepo of a nix based homelab. 

# Layout

```
hosts/<host>/      per-machine configuration (sorbet, eclair)
modules/flake/     flake-parts plumbing: deploy nodes, systems, checks
services/          third-party services you configure
pkgs/              third-party software you package
apps/              source for services and tools, colocated with their _package.nix and _module.nix
secrets/           sops-encrypted, kept central on purpose
docs/              (planned) runbooks and decision records
```

All .nix files under hosts/, modules/ and services/ are auto-imported by import-tree as flake-parts modules (following
the dendritic pattern). Any path containing /_ is skipped — that is how a directory keeps helper files next to its
module without them being evaluated as flake-parts modules.

Service modules contribute to the flake via:

    flake.nixosModules.* — applied to sorbet
    flake.eclairNixosModules.* — applied to eclair
    flake.caddyVirtualHosts — Caddy site blocks, also read by haproxy to auto-generate SNI ACLs

Adding a new public service: declare flake.caddyVirtualHosts."myservice.ext.kuipr.de" in the service module — haproxy picks it up automatically on next deploy.

# Architecture

Eclair is a VPS running CrowdSec, HAProxy and Tailscale with its main purpose being a proxy for external domains
(`*.ext.kuipr.de`). While sorbet is the main homelab server serving most of the services and tools. Stuff that should
only be accessible from inside the LAN (or through VPN) lives on the (`*.int.kuipr.de`) subdomain.


# Secrets

Secrets are encrypted with sops-nix using age keys. Files live under secrets/<host>/<service>.
Instead of normal sops this homelab relies on `opsops`, a 1Password sops wrapper. Opsops allows for the following:

```
A wrapper that integrates sops with 1Password

Usage: opsops [OPTIONS] <COMMAND>

Commands:
  list-config       Parse and display the .sops.yaml for this project
  generate-age-key  Generate an age key pair
  edit              Edit a file using sops with a key from 1password
  encrypt           Encrypt a file using sops
  decrypt           Decrypt a file using sops
  doctor            Troubleshoot your current config
  init              Initialize opsops
  read              Read an encrypted file and print its decrypted content to stdout
  target-keys       Set up encryption patterns for a file
  help              Print this message or the help of the given subcommand(s)

Options:
      --sops-file <SOPS_FILE>  Path to the .sops.yaml file
      --op-item <OP_ITEM>      1Password item reference (e.g. op://MyVault/MyItem/MyField)
  -h, --help                   Print help
  -V, --version                Print version
```


You should basically only ever use encypt/decrypt and read, for all other actions **delegate to the user**. Never read
the sops private keys directly from 1Password!

# Deployment 

Deployment runs through deploy-rs using the justfile recipe: `just deploy <host>`. With host either being sorbet or
eclair. Before being able to deploy you nedd to run `nix fmt` and `nix flake check`. Additionally all changes need to be
commited before deploying.

# Debugging

In case its useful for debugging you can ssh into either server after asking. Then simply run `ssh <host>` to ssh into a
host.

# Committing

When working on a new feature or bug fix, create a new branch first. For commit messages use the conventional commit
standard.

