_: {
  # Kustomize rejects the same namespace object in two app directories.
  flake.k8sModules.auth-namespace = _: {
    kubernetes.resources.namespaces.auth = {};
  };
}
