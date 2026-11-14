# Homelab Monorepo

Nix flake for two hosts: `sorbet` (LAN server) and `eclair` (VPS, public proxy).

Layout, architecture, secrets, deploy model and commit rules are in
[AGENTS.md](./AGENTS.md). Runbooks and decision records live in Obsidian under
`2 Resources/Homelab`.

```
just            # list tasks
just check      # nix fmt + nix flake check
just test sorbet   # push to testing-sorbet for a comin test activation
```
