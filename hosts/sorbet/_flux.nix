{
  config,
  lib,
  pkgs,
  ...
}: let
  install = pkgs.runCommand "gotk-components.yaml" {} ''
    export HOME=$TMPDIR
    ${lib.getExe pkgs.fluxcd} install --export > $out
  '';

  # Seed only. Flux owns these objects once they exist, so this never overwrites them.
  sync = pkgs.writeText "flux-sync.yaml" ''
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
in {
  systemd.services.flux-bootstrap = {
    description = "Install Flux and point it at the rendered branch";
    wantedBy = ["multi-user.target"];
    after = ["k3s.service" "network-online.target"];
    wants = ["k3s.service" "network-online.target"];
    path = [config.services.k3s.package pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 15;
    };
    script = ''
      set -euo pipefail

      for _ in $(seq 1 150); do
        k3s kubectl get --raw /readyz >/dev/null 2>&1 && break
        sleep 2
      done

      # Controllers are reapplied on every boot: the node owns them, Flux owns the workloads.
      k3s kubectl apply -f ${install}

      if k3s kubectl -n flux-system get gitrepository/flux-system >/dev/null 2>&1; then
        echo "flux already bootstrapped"
        exit 0
      fi

      k3s kubectl wait --for=condition=established --timeout=120s \
        crd/gitrepositories.source.toolkit.fluxcd.io \
        crd/kustomizations.kustomize.toolkit.fluxcd.io
      k3s kubectl apply -f ${sync}
    '';
  };
}
