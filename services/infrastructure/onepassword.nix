_: {
  # Copied verbatim from 1Password/onepassword-operator, config/crd/bases, v1.12.1.
  flake.k8sFiles.onepassword-crd = builtins.readFile ./_onepassword/onepassworditems.yaml;

  flake.k8sModules.onepassword = _: {
    kubernetes.resources = {
      namespaces.onepassword = {};

      serviceAccounts.onepassword-operator.metadata.namespace = "onepassword";

      clusterRoles.onepassword-operator.rules = [
        {
          apiGroups = [""];
          resources = ["configmaps" "endpoints" "events" "namespaces" "persistentvolumeclaims" "pods" "secrets" "services" "services/finalizers"];
          verbs = ["create" "delete" "get" "list" "patch" "update" "watch"];
        }
        {
          # AUTO_RESTART patches Deployments when a OnePasswordItem changes.
          apiGroups = ["apps"];
          resources = ["daemonsets" "deployments" "replicasets" "statefulsets"];
          verbs = ["create" "delete" "get" "list" "patch" "update" "watch"];
        }
        {
          apiGroups = ["apps"];
          resources = ["deployments/finalizers" "deployments/status"];
          verbs = ["get" "patch" "update"];
        }
        {
          # Leader election.
          apiGroups = ["coordination.k8s.io"];
          resources = ["leases"];
          verbs = ["create" "get" "list" "update"];
        }
        {
          apiGroups = ["onepassword.com"];
          resources = ["*" "onepassworditems" "onepassworditems/finalizers" "onepassworditems/status"];
          verbs = ["create" "delete" "get" "list" "patch" "update" "watch"];
        }
      ];

      clusterRoleBindings.onepassword-operator = {
        roleRef = {
          apiGroup = "rbac.authorization.k8s.io";
          kind = "ClusterRole";
          name = "onepassword-operator";
        };
        subjects = [
          {
            kind = "ServiceAccount";
            name = "onepassword-operator";
            namespace = "onepassword";
          }
        ];
      };

      deployments.onepassword-operator = {
        metadata.namespace = "onepassword";
        spec = {
          replicas = 1;
          selector.matchLabels.app = "onepassword-operator";
          template = {
            metadata.labels.app = "onepassword-operator";
            spec = {
              serviceAccountName = "onepassword-operator";
              securityContext = {
                runAsNonRoot = true;
                seccompProfile.type = "RuntimeDefault";
              };
              containers.manager = {
                image = "docker.io/1password/onepassword-operator:1.12.1";
                command = ["/manager"];
                args = [
                  "--leader-elect"
                  "--health-probe-bind-address=:8081"
                ];
                env = [
                  {
                    name = "OPERATOR_NAME";
                    value = "onepassword-operator";
                  }
                  {
                    name = "POD_NAME";
                    valueFrom.fieldRef.fieldPath = "metadata.name";
                  }
                  {
                    # Empty watches every namespace.
                    name = "WATCH_NAMESPACE";
                    value = "";
                  }
                  {
                    name = "POLLING_INTERVAL";
                    value = "10";
                  }
                  {
                    # Restarts consuming Deployments when a Secret changes.
                    name = "AUTO_RESTART";
                    value = "true";
                  }
                  {
                    name = "OP_SERVICE_ACCOUNT_TOKEN";
                    valueFrom.secretKeyRef = {
                      name = "onepassword-service-account-token";
                      key = "token";
                    };
                  }
                ];
                ports.health.containerPort = 8081;
                startupProbe = {
                  httpGet = {
                    path = "/healthz";
                    port = 8081;
                  };
                  # The 1Password client init can exceed the 30s default budget.
                  periodSeconds = 10;
                  failureThreshold = 30;
                };
                readinessProbe.httpGet = {
                  path = "/readyz";
                  port = 8081;
                };
                livenessProbe.httpGet = {
                  path = "/healthz";
                  port = 8081;
                };
                securityContext = {
                  allowPrivilegeEscalation = false;
                  readOnlyRootFilesystem = true;
                  capabilities.drop = ["ALL"];
                };
                resources = {
                  requests = {
                    cpu = "20m";
                    memory = "64Mi";
                  };
                  limits = {
                    cpu = "200m";
                    memory = "256Mi";
                  };
                };
              };
            };
          };
        };
      };
    };
  };
}
