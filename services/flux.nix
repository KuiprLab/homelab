_: {
  # Inline YAML: Flux kinds need no kubenix schema, so no customTypes registry is kept.
  flake.k8sFiles.flux = /* yaml */ ''
    apiVersion: source.toolkit.fluxcd.io/v1
    kind: GitRepository
    metadata:
      name: flux-system
      namespace: flux-system
    spec:
      interval: 1m
      url: https://github.com/KuiprLab/homelab
      ref:
        branch: rendered
    ---
    apiVersion: kustomize.toolkit.fluxcd.io/v1
    kind: Kustomization
    metadata:
      name: flux-system
      namespace: flux-system
    spec:
      interval: 10m
      path: ./dev
      prune: true
      wait: true
      sourceRef:
        kind: GitRepository
        name: flux-system
  '';
}
