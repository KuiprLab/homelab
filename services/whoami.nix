_: {
  flake.k8sModules.whoami = {...}: {
    kubernetes.resources = {
      namespaces.whoami = {};

      deployments.whoami = {
        metadata.namespace = "whoami";
        spec = {
          replicas = 1;
          selector.matchLabels.app = "whoami";
          template = {
            metadata.labels.app = "whoami";
            spec.containers.whoami = {
              image = "docker.io/traefik/whoami:v1.10";
              ports.http.containerPort = 80;
              resources = {
                requests = {
                  cpu = "10m";
                  memory = "16Mi";
                };
                limits = {
                  memory = "64Mi";
                };
              };
            };
          };
        };
      };

      services.whoami = {
        metadata.namespace = "whoami";
        spec = {
          selector.app = "whoami";
          ports.http = {
            port = 80;
            targetPort = 80;
          };
        };
      };
    };
  };
}
