_: {
  flake.k8sModules.headlamp = _: {
    kubernetes.resources = {
      namespaces.headlamp = {};

      serviceAccounts.headlamp.metadata.namespace = "headlamp";

      clusterRoles.headlamp.rules = [
        {
          # Read-only everywhere: the Flux plugin reads its CRDs through the same grant.
          apiGroups = ["*"];
          resources = ["*"];
          verbs = ["get" "list" "watch"];
        }
      ];

      clusterRoleBindings.headlamp = {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = "headlamp";
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = "headlamp";
            namespace = "headlamp";
          }
        ];
      };

      deployments.headlamp = {
        metadata.namespace = "headlamp";
        spec = {
          replicas = 1;
          selector.matchLabels.app = "headlamp";
          template = {
            metadata.labels.app = "headlamp";
            spec = {
              serviceAccountName = "headlamp";
              securityContext = {
                runAsUser = 100;
                runAsGroup = 101;
                fsGroup = 101;
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              initContainers.plugins = {
                image = "ghcr.io/headlamp-k8s/headlamp-plugin-flux:v0.7.0";
                command = [
                  "/bin/sh"
                  "-c"
                  "mkdir -p /build/plugins && cp -r /plugins/* /build/plugins/ && chown -R 100:101 /build"
                ];
                securityContext = {
                  # The image ships the plugin as root; only this container needs it.
                  runAsNonRoot = false;
                  runAsUser = 0;
                  runAsGroup = 0;
                  allowPrivilegeEscalation = false;
                  # chown needs CAP_CHOWN; the default drop list removes it.
                  capabilities = {
                    add = ["CHOWN"];
                    drop = ["ALL"];
                  };
                };
                volumeMounts = [
                  {
                    name = "plugins";
                    mountPath = "/build/plugins";
                  }
                ];
                resources = {
                  requests = {
                    cpu = "10m";
                    memory = "32Mi";
                  };
                  limits.memory = "64Mi";
                };
              };
              containers.headlamp = {
                image = "ghcr.io/headlamp-k8s/headlamp:v0.46.0";
                args = [
                  "-in-cluster"
                  "-plugins-dir=/build/plugins"
                  "-watch-plugins-changes"
                ];
                ports.http.containerPort = 4466;
                volumeMounts = [
                  {
                    name = "plugins";
                    mountPath = "/build/plugins";
                  }
                ];
                readinessProbe.httpGet = {
                  path = "/";
                  port = 4466;
                };
                livenessProbe.httpGet = {
                  path = "/";
                  port = 4466;
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  capabilities.drop = ["ALL"];
                };
                resources = {
                  requests = {
                    cpu = "20m";
                    memory = "64Mi";
                  };
                  limits = {
                    cpu = "500m";
                    memory = "256Mi";
                  };
                };
              };
              volumes = [
                {
                  name = "plugins";
                  emptyDir = {};
                }
              ];
            };
          };
        };
      };

      services.headlamp = {
        metadata.namespace = "headlamp";
        spec = {
          selector.app = "headlamp";
          ports.http = {
            port = 80;
            targetPort = 4466;
          };
        };
      };

      ingresses.headlamp = {
        metadata.namespace = "headlamp";
        spec = {
          ingressClassName = "traefik";
          rules = [
            {
              host = "headlamp.192.168.139.139.sslip.io";
              http.paths = [
                {
                  path = "/";
                  pathType = "Prefix";
                  backend.service = {
                    name = "headlamp";
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
