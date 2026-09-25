# Homelab monorepo

## Hosts

| Host     | Role                | Location            |
| -------- | ------------------- | ------------------- |
| `sorbet` | Main homelab server | LAN `192.168.0.85`  |
| `eclair` | Public-facing VPS   | Tailnet + public IP |

## Architecture

```
Internet
   │
   ▼
eclair (VPS)
  haproxy :443 — TCP SNI passthrough
  CrowdSec — nftables IP banning
   │ tailnet
   ▼
sorbet (LAN)
  caddy — TLS termination (ACME via Bunny DNS)
  services — Navidrome, Home Assistant, etc.
```

`*.ext.kuipr.de` DNS records point to eclair's public IP. haproxy inspects the TLS SNI header, matches against all `*.ext.kuipr.de` virtual hosts declared in the flake, and TCP-proxies the connection to sorbet over Tailscale. Caddy on sorbet terminates TLS end-to-end — eclair never sees plaintext.

`*.int.kuipr.de` resolves to `192.168.0.85` via dnsmasq wildcard — LAN only, not routed through eclair.

## Repository layout

```
hosts/<host>/      per-machine configuration (sorbet, eclair)
modules/flake/     flake-parts plumbing: deploy nodes, systems, checks
services/          third-party services you configure
pkgs/              third-party software you package
apps/              (planned) source for daemons you write, colocated
                   with their _package.nix and _module.nix
secrets/           sops-encrypted, kept central on purpose
docs/              (planned) runbooks and decision records
```

All `.nix` files under `hosts/`, `modules/` and `services/` are auto-imported
by `import-tree` as flake-parts modules. Any path containing `/_` is skipped —
that is how a directory keeps helper files next to its module without them
being evaluated as flake-parts modules.

`pkgs/` is deliberately outside the import-tree roots: its files are a
derivation and a NixOS module, imported by hand from `services/unifi.nix`.

Service modules contribute to the flake via:

- `flake.nixosModules.*` — applied to **sorbet**
- `flake.eclairNixosModules.*` — applied to **eclair**
- `flake.caddyVirtualHosts` — Caddy site blocks, also read by haproxy to auto-generate SNI ACLs

Adding a new public service: declare `flake.caddyVirtualHosts."myservice.ext.kuipr.de"` in the service module — haproxy picks it up automatically on next deploy.

## Secrets

Secrets are encrypted with [sops-nix](https://github.com/Mic92/sops-nix) using age keys. Files live under `secrets/<host>/<service>`.

| Secret file                     | Used by                                        |
| ------------------------------- | ---------------------------------------------- |
| `secrets/sorbet/caddy`          | Caddy — `BUNNY_API_KEY` for ACME DNS challenge |
| `secrets/sorbet/tailscale`      | sorbet tailscale auth key                      |
| `secrets/sorbet/homepage`       | Homepage dashboard env vars                    |
| `secrets/sorbet/gatus`          | Gatus — Discord webhook                        |
| `secrets/sorbet/github-runner`  | GitHub Actions runner token                    |
| `secrets/sorbet/rclone`         | rclone Google Drive config                     |
| `secrets/sorbet/beets`          | beets config                                   |
| `secrets/eclair/tailscale`      | eclair tailscale auth key                      |
| `secrets/sorbet/homelab-bot.env` | homelab-bot — Discord token, app ID, guild ID |
| `secrets/shared/deploy-webhook` | Discord deploy notifications                   |

Both hosts share a single age key listed in `.sops.yaml`.

### Age key

Both hosts use the same age private key stored at `/var/lib/sops/age-key.txt`. This file must exist before NixOS activation — sops-nix will fail to decrypt secrets without it.

The key is stored in 1Password. Upload it to either host with:

```bash
op read "op://Personal/sorbet.nix/Private Key" \
  | ssh root@sorbet "mkdir -p /var/lib/sops && cat > /var/lib/sops/age-key.txt && chmod 400 /var/lib/sops/age-key.txt"

op read "op://Personal/sorbet.nix/Private Key" \
  | ssh root@eclair "mkdir -p /var/lib/sops && cat > /var/lib/sops/age-key.txt && chmod 400 /var/lib/sops/age-key.txt"
```

## Deployment

### Deploy sorbet

```bash
just deploy sorbet
```

### Deploy eclair

```bash
just deploy eclair
```

The `deploy` recipe calls `scripts/deploy.sh`, which uses deploy-rs for remote hosts. `remoteBuild = false` for eclair — the closure is built locally and pushed to the VPS.

### Fresh install (nixos-anywhere)

```bash
just install root@<target-ip>
```

Installs NixOS from scratch via [nixos-anywhere](https://github.com/nix-community/nixos-anywhere). The `config` variable at the top of the justfile controls which flake target is installed.

### Build without deploying

```bash
just build
```

Runs `nix fmt` + `nix flake check` + builds the sorbet toplevel locally (requires a Linux builder on macOS).

## CrowdSec (eclair)

CrowdSec runs on eclair as agent + nftables firewall bouncer. The agent watches haproxy and sshd journals for attack signals and feeds decisions to the bouncer, which DROPs banned IPs via nftables before they reach haproxy.

### Check active bans

```bash
ssh root@eclair cscli decisions list
```

### Check alerts

```bash
ssh root@eclair cscli alerts list
```

### Update hub (collections/parsers/scenarios)

```bash
ssh root@eclair cscli hub update && cscli hub upgrade
```

### Unban an IP

```bash
ssh root@eclair cscli decisions delete --ip <ip>
```

## Adding a new external service

1. In the service's `.nix` file, add a `flake.caddyVirtualHosts."myservice.ext.kuipr.de"` entry.
2. Point `myservice.ext.kuipr.de` DNS A record to eclair's public IP.
3. Deploy sorbet (caddy picks up new vhost) then eclair (haproxy regenerates SNI ACLs).

No other changes needed — SNI routing is derived automatically from `caddyVirtualHosts`.

## Formatting and checks

```bash
nix fmt .        # formats every language in the tree
nix flake check  # treefmt + deadnix + statix
```

`nix fmt` is treefmt, configured once in `modules/flake/treefmt.nix`. It
currently drives alejandra (Nix) and shfmt (shell); adding Go, Rust or
prettier is one line there and nothing anywhere else. Formatting is also a
flake check, so CI fails on an unformatted tree.

deadnix and statix stay separate checks on purpose — they inspect, they do
not rewrite.

## Updating flake inputs

```bash
just update-inputs
```

## Running beets on sorbet

```bash
just beet import ~/Downloads/album
just beet <any beet command>
```
