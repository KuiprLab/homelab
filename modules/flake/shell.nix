_: {
  perSystem = {pkgs, ...}: {
    devShells.default = pkgs.mkShell {
      packages = with pkgs; [
        kubectl
        kubernetes-helm
        kustomize
        kubectx
        k9s
        stern
        yq-go
      ];

      shellHook = ''
        export KUBECONFIG="''${KUBECONFIG:-$HOME/.kube/sorbet-dev.yaml}"
        echo "kube shell -- KUBECONFIG=$KUBECONFIG"
        echo
        echo "  just kubeconfig        fetch the dev cluster kubeconfig"
        echo "  kubectl get nodes      check the cluster"
        echo
      '';
    };
  };
}
