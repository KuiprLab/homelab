_: {
  flake.k8sModules.whoami = _: {
    kubernetes.resources = {
      namespaces.whoami = {};

      deployments.whoami = {
        metadata.namespace = "whoami";
        spec = {
          replicas = 1;
          selector.matchLabels.app = "whoami";
          template = {
            metadata.labels.app = "whoami";
            spec = {
              automountServiceAccountToken = false;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65532;
                runAsGroup = 65532;
                seccompProfile.type = "RuntimeDefault";
              };
              containers.whoami = {
                image = "docker.io/traefik/whoami:v1.10";
                args = ["-port=8080"];
                ports.http.containerPort = 8080;
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = ["ALL"];
                };
                readinessProbe.httpGet = {
                  path = "/";
                  port = 8080;
                };
                livenessProbe.httpGet = {
                  path = "/";
                  port = 8080;
                };
                resources = {
                  requests = {
                    cpu = "10m";
                    memory = "16Mi";
                  };
                  limits = {
                    cpu = "100m";
                    memory = "64Mi";
                  };
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
            targetPort = 8080;
          };
        };
      };

      ingresses.whoami = {
        metadata.namespace = "whoami";
        spec = {
          ingressClassName = "traefik";
          rules = [
            {
              host = "whoami.192.168.139.139.sslip.io";
              http.paths = [
                {
                  path = "/";
                  pathType = "Prefix";
                  backend.service = {
                    name = "whoami";
                    port.number = 80;
                  };
                }
              ];
            }
          ];
        };
      };
    };
  };
}
