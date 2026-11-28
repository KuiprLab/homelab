_: {
  flake.k8sModules.flux = {kubernetes, ...}: {
    kubernetes.customTypes = [
      {
        group = "source.toolkit.fluxcd.io";
        version = "v1";
        kind = "GitRepository";
        attrName = "gitRepositories";
      }
      {
        group = "kustomize.toolkit.fluxcd.io";
        version = "v1";
        kind = "Kustomization";
        attrName = "kustomizations";
      }
    ];

    kubernetes.resources = {
      gitRepositories.flux-system = {
        metadata.namespace = "flux-system";
        spec = {
          interval = "1m";
          url = "https://github.com/KuiprLab/homelab";
          ref.branch = "rendered";
        };
      };

      kustomizations.flux-system = {
        metadata.namespace = "flux-system";
        spec = {
          interval = "10m";
          path = "./dev";
          prune = true;
          wait = true;
          sourceRef = {
            kind = "GitRepository";
            name = "flux-system";
          };
        };
      };
    };
  };
}
