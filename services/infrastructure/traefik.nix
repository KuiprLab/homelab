_: {
  flake.k8sModules.traefik = _: {
    kubernetes.resources = {
      namespaces.traefik = {};

      serviceAccounts.traefik.metadata.namespace = "traefik";

      clusterRoles.traefik.rules = [
        {
          apiGroups = [""];
          resources = ["services" "secrets" "nodes" "configmaps"];
          verbs = ["get" "list" "watch"];
        }
        {
          apiGroups = ["discovery.k8s.io"];
          resources = ["endpointslices"];
          verbs = ["get" "list" "watch"];
        }
        {
          # Routes: which Ingress belongs to this controller.
          apiGroups = ["networking.k8s.io"];
          resources = ["ingresses" "ingressclasses"];
          verbs = ["get" "list" "watch"];
        }
        {
          # Writes the node address into `kubectl get ingress`.
          apiGroups = ["networking.k8s.io"];
          resources = ["ingresses/status"];
          verbs = ["update"];
        }
      ];

      clusterRoleBindings.traefik = {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = "traefik";
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = "traefik";
            namespace = "traefik";
          }
        ];
      };

      ingressClasses.traefik.spec.controller = "traefik.io/ingress-controller";

      deployments.traefik = {
        metadata.namespace = "traefik";
        spec = {
          replicas = 1;
          selector.matchLabels.app = "traefik";
          template = {
            metadata.labels.app = "traefik";
            spec = {
              serviceAccountName = "traefik";
              securityContext = {
                runAsUser = 65532;
                runAsGroup = 65532;
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              containers.traefik = {
                image = "docker.io/library/traefik:v3.8.0";
                args = [
                  # Unprivileged ports: the Service publishes 80 and 443 on top of them.
                  "--entrypoints.web.address=:8000"
                  "--entrypoints.websecure.address=:8443"
                  "--entrypoints.traefik.address=:8080"
                  "--providers.kubernetesingress=true"
                  "--providers.kubernetesingress.ingressclass=traefik"
                  "--providers.kubernetesingress.ingressendpoint.publishedservice=traefik/traefik"
                  "--api.dashboard=false"
                  "--ping=true"
                  "--log.level=INFO"
                  "--accesslog=true"
                  "--global.checknewversion=false"
                  "--global.sendanonymoususage=false"
                ];
                ports = {
                  web.containerPort = 8000;
                  websecure.containerPort = 8443;
                  traefik.containerPort = 8080;
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = ["ALL"];
                };
                readinessProbe.httpGet = {
                  path = "/ping";
                  port = 8080;
                };
                livenessProbe.httpGet = {
                  path = "/ping";
                  port = 8080;
                };
                resources = {
                  requests = {
                    cpu = "50m";
                    memory = "128Mi";
                  };
                  limits = {
                    cpu = "500m";
                    memory = "256Mi";
                  };
                };
              };
            };
          };
        };
      };

      services.traefik = {
        metadata.namespace = "traefik";
        spec = {
          type = "LoadBalancer";
          selector.app = "traefik";
          ports = {
            http = {
              port = 80;
              targetPort = 8000;
            };
            https = {
              port = 443;
              targetPort = 8443;
            };
          };
        };
      };
    };
  };
}
