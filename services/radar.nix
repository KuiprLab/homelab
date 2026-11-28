_: {
  flake.k8sModules.radar = _: {
    kubernetes.resources = {
      namespaces.radar = {};

      serviceAccounts.radar.metadata.namespace = "radar";

      clusterRoles.radar-read.rules = [
        {
          apiGroups = ["*"];
          resources = ["*"];
          verbs = ["get" "list" "watch"];
        }
      ];

      clusterRoleBindings.radar-read = {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = "radar-read";
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = "radar";
            namespace = "radar";
          }
        ];
      };

      deployments.radar = {
        metadata.namespace = "radar";
        spec = {
          replicas = 1;
          selector.matchLabels.app = "radar";
          template = {
            metadata.labels.app = "radar";
            spec = {
              serviceAccountName = "radar";
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65532;
                runAsGroup = 65532;
                fsGroup = 65532;
                seccompProfile.type = "RuntimeDefault";
              };
              containers.radar = {
                image = "ghcr.io/skyhook-io/radar:1.22.0";
                args = [
                  "--port=9280"
                  "--listen-address=0.0.0.0"
                  "--no-browser"
                  # Radar refuses unknown Host headers, so the Ingress name must be listed.
                  "--allowed-hosts=radar.radar,radar.dev.kuipr.de"
                ];
                ports.http.containerPort = 9280;
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = ["ALL"];
                };
                readinessProbe.httpGet = {
                  path = "/api/health";
                  port = 9280;
                };
                livenessProbe.httpGet = {
                  path = "/api/health";
                  port = 9280;
                };
                resources = {
                  requests = {
                    cpu = "100m";
                    memory = "256Mi";
                  };
                  limits = {
                    cpu = "500m";
                    memory = "512Mi";
                  };
                };
              };
            };
          };
        };
      };

      services.radar = {
        metadata.namespace = "radar";
        spec = {
          selector.app = "radar";
          ports.http = {
            port = 80;
            targetPort = 9280;
          };
        };
      };

      ingresses.radar = {
        metadata.namespace = "radar";
        spec = {
          ingressClassName = "traefik";
          rules = [
            {
              host = "radar.dev.kuipr.de";
              http.paths = [
                {
                  path = "/";
                  pathType = "Prefix";
                  backend.service = {
                    name = "radar";
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
