This is the monorepo of a nix based homelab. 

# Layout

```
hosts/<host>/      per-machine configuration (sorbet, eclair)
modules/flake/     flake-parts plumbing: systems, checks, formatting
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

# Architecture

Eclair is a VPS running Pangolin (with Traefik/Gerbil) with its main purpose being a proxy for external domains
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

Both hosts run comin as a pull-based GitOps agent. comin polls `main` every 300 s, builds the new commit on the host,
and runs `switch-to-configuration switch`. There is no inbound deploy path, deploy key, or self-hosted runner.

A push to `main` is the deploy trigger. Before you push, run `nix fmt` and `nix flake check`.

To test one host before `main`: rebase the branch on `main` with `git rebase --gpg-sign main`, then push it to
`testing-<host>` (a force-push is fine, the branch is a pointer). comin on `<host>` then runs
`switch-to-configuration test`; the bootloader does not change. Only one testing branch per host is active. The last
push wins.

The ref is `testing-<host>`, not `testing/<host>`: git cannot hold `testing/sorbet` and `testing/sorbet/<feature>` at
the same time, and the collision is fatal rather than cosmetic. A fetch that meets both writes a directory where the
branch ref belongs, and every later fetch of that remote fails, including `main`.

Check status with `ssh <host> comin status`. Logs are in `journalctl -u comin`. State lives in `/var/lib/comin`.

# Debugging

In case its useful for debugging you can ssh into either server after asking. Then simply run `ssh <host>` to ssh into a
host.

# Committing

Create a branch before you work (`feat/<name>` or `fix/<name>`). For a change that must be tested on a host, rebase it
on `main` with `git rebase --gpg-sign main` and push it to `testing-<host>`, where `<host>` is `sorbet` or `eclair`.
comin rejects a testing commit that is not on top of `main` or is not signed.

Once the testing branch carries commits, open a draft pull request for the feature branch with the GitHub CLI
(`gh pr create --draft`). Keep it a draft until the host test passes, then mark it ready.

For a change that does not need a host test, use `feat/<name>` or `fix/<name>`. Use conventional commit messages. A
push to `main` deploys to both hosts. Merge with a merge commit or a squash merge. Do not use "Rebase and merge" unless
every commit is signed.


# Comments

Do not add comments by default. A comment is allowed only for a workaround, a non-obvious constraint (ordering, activation, external magic value), or a decision that looks like a mistake. One line, 100 characters maximum. Write why, never what.

Do not write file headers, section dividers, JSDoc blocks, history, or examples. The code and the commit message carry the rest.

# Documentation

Documentation lives in Obsidian. You can access it using the obsidian cli `obsidian` and all of the Docs live in `2 Resources/Homelab`.
Do not write outside of that directory, but you can and should link inline to related items. After adding major
feartures or rewrites, update the Documentation. The documentation should be as stable as possible i.e. not contain
information that changes frequently or is "brittle". Especially document quirks and steps that have to be done
imperatively. Writing style should be terse and technical. Do not use filler words, and such. Keep to the  ASD-STE100
Simplified Technical English standard!
