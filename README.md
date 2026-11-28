# Homelab Monorepo

Nix flake for three hosts: `sorbet` (single-node k3s cluster), `eclair` (VPS,
public proxy) and `crossaint` (VM). `sorbet-dev` runs the sorbet config on the
OrbStack machine for development.

Layout, architecture, secrets, deploy model and commit rules are in
[AGENTS.md](./AGENTS.md). Runbooks and decision records live in Obsidian under
`2 Resources/Homelab`.

```
nix develop        # kubectl, helm, k9s; KUBECONFIG points at the dev cluster
just deploy-dev    # activate sorbet-dev on the OrbStack machine (192.168.139.139)
just kubeconfig    # fetch the dev cluster kubeconfig into ~/.kube/sorbet-dev.yaml
just check         # nix fmt + nix flake check
just test sorbet   # push to testing-sorbet for a comin test activation
```
