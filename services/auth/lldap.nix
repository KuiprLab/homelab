_: {
  flake.k8sModules.lldap = _: {
    kubernetes.resources = {
      persistentVolumeClaims.lldap-data = {
        metadata.namespace = "auth";
        spec = {
          accessModes = ["ReadWriteOnce"];
          storageClassName = "local-path";
          resources.requests.storage = "1Gi";
        };
      };

      onePasswordItems.lldap = {
        metadata.namespace = "auth";
        spec.itemPath = "vaults/Personal/items/lldap";
      };

      deployments.lldap = {
        metadata.namespace = "auth";
        spec = {
          replicas = 1;
          strategy.type = "Recreate";
          selector.matchLabels.app = "lldap";
          template = {
            metadata.labels.app = "lldap";
            spec = {
              automountServiceAccountToken = false;
              securityContext.seccompProfile.type = "RuntimeDefault";
              containers.lldap = {
                image = "ghcr.io/lldap/lldap:v0.6.3";
                # Secret keys are the 1Password field labels: LLDAP_JWT_SECRET, LLDAP_LDAP_USER_PASS.
                envFrom = [{secretRef.name = "lldap";}];
                env = [
                  {
                    name = "LLDAP_LDAP_BASE_DN";
                    value = "dc=kuipr,dc=de";
                  }
                  {
                    name = "LLDAP_LDAP_USER_DN";
                    value = "admin";
                  }
                  {
                    name = "LLDAP_HTTP_URL";
                    value = "http://0.0.0.0:17170";
                  }
                ];
                ports = {
                  ldap.containerPort = 3890;
                  http.containerPort = 17170;
                };
                volumeMounts = [
                  {
                    name = "data";
                    mountPath = "/data";
                  }
                ];
                readinessProbe.httpGet = {
                  path = "/health";
                  port = 17170;
                };
                livenessProbe.httpGet = {
                  path = "/health";
                  port = 17170;
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = ["ALL"];
                };
                resources = {
                  requests = {
                    cpu = "20m";
                    memory = "128Mi";
                  };
                  limits = {
                    cpu = "300m";
                    memory = "256Mi";
                  };
                };
              };
              volumes = [
                {
                  name = "data";
                  persistentVolumeClaim.claimName = "lldap-data";
                }
              ];
            };
          };
        };
      };

      services.lldap = {
        metadata.namespace = "auth";
        spec = {
          selector.app = "lldap";
          ports = {
            ldap = {
              port = 3890;
              targetPort = 3890;
            };
            http = {
              port = 17170;
              targetPort = 17170;
            };
          };
        };
      };

      ingresses.lldap = {
        metadata.namespace = "auth";
        spec = {
          ingressClassName = "traefik";
          rules = [
            {
              host = "lldap.dev.kuipr.de";
              http.paths = [
                {
                  path = "/";
                  pathType = "Prefix";
                  backend.service = {
                    name = "lldap";
                    port.number = 17170;
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
