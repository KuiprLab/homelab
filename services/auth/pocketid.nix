_: {
  flake.k8sModules.pocketid = _: {
    kubernetes.resources = {
      persistentVolumeClaims.pocket-id-data = {
        metadata.namespace = "auth";
        spec = {
          accessModes = ["ReadWriteOnce"];
          storageClassName = "local-path";
          resources.requests.storage = "1Gi";
        };
      };

      onePasswordItems.pocket-id = {
        metadata.namespace = "auth";
        spec.itemPath = "vaults/Personal/items/pocket-id";
      };

      deployments.pocket-id = {
        metadata.namespace = "auth";
        spec = {
          replicas = 1;
          strategy.type = "Recreate";
          selector.matchLabels.app = "pocket-id";
          template = {
            metadata.labels.app = "pocket-id";
            spec = {
              automountServiceAccountToken = false;
              securityContext = {
                runAsNonRoot = true;
                runAsUser = 65532;
                runAsGroup = 65532;
                fsGroup = 65532;
                seccompProfile.type = "RuntimeDefault";
              };
              containers.pocket-id = {
                image = "docker.io/pocketid/pocket-id:v2.19.3";
                # ENCRYPTION_KEY comes from the 1Password item.
                envFrom = [{secretRef.name = "pocket-id";}];
                env = [
                  {
                    # Must match the Ingress host, or the OIDC redirects point elsewhere.
                    name = "APP_URL";
                    value = "http://pocket-id.dev.kuipr.de";
                  }
                  {
                    name = "LDAP_ENABLED";
                    value = "true";
                  }
                  {
                    name = "LDAP_URL";
                    value = "ldap://lldap.auth.svc.cluster.local:3890";
                  }
                  {
                    name = "LDAP_BASE";
                    value = "dc=kuipr,dc=de";
                  }
                  {
                    name = "LDAP_BIND_DN";
                    value = "uid=admin,ou=people,dc=kuipr,dc=de";
                  }
                  {
                    name = "LDAP_ADMIN_GROUP_NAME";
                    value = "admin";
                  }
                  {
                    name = "LDAP_ATTRIBUTE_USER_USERNAME";
                    value = "uid";
                  }
                  {
                    name = "LDAP_ATTRIBUTE_USER_EMAIL";
                    value = "mail";
                  }
                  {
                    name = "LDAP_ATTRIBUTE_USER_FIRST_NAME";
                    value = "givenName";
                  }
                  {
                    name = "LDAP_ATTRIBUTE_USER_LAST_NAME";
                    value = "sn";
                  }
                  {
                    name = "LDAP_ATTRIBUTE_USER_UNIQUE_IDENTIFIER";
                    value = "entryUUID";
                  }
                  {
                    name = "LDAP_ATTRIBUTE_GROUP_NAME";
                    value = "cn";
                  }
                  {
                    name = "LDAP_ATTRIBUTE_GROUP_UNIQUE_IDENTIFIER";
                    value = "entryUUID";
                  }
                ];
                ports.http.containerPort = 1411;
                volumeMounts = [
                  {
                    name = "data";
                    mountPath = "/app/data";
                  }
                ];
                # The image ships its own health subcommand; there is no HTTP probe path.
                readinessProbe.exec.command = ["/app/pocket-id" "healthcheck"];
                livenessProbe.exec.command = ["/app/pocket-id" "healthcheck"];
                securityContext = {
                  allowPrivilegeEscalation = false;
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
                  persistentVolumeClaim.claimName = "pocket-id-data";
                }
              ];
            };
          };
        };
      };

      services.pocket-id = {
        metadata.namespace = "auth";
        spec = {
          selector.app = "pocket-id";
          ports.http = {
            port = 1411;
            targetPort = 1411;
          };
        };
      };

      ingresses.pocket-id = {
        metadata.namespace = "auth";
        spec = {
          ingressClassName = "traefik";
          rules = [
            {
              host = "pocket-id.dev.kuipr.de";
              http.paths = [
                {
                  path = "/";
                  pathType = "Prefix";
                  backend.service = {
                    name = "pocket-id";
                    port.number = 1411;
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
