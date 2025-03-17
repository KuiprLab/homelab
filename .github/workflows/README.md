# Flux Validation System

This repository includes an automated validation system that ensures your GitOps configurations are valid before they're applied to your cluster. This helps prevent deployment failures and potential cluster outages.

## How It Works

The validation system consists of two GitHub Actions workflows:

### 1. `validate-and-protect.yaml`

This workflow runs on every push and pull request to the main branches and performs:

- Syntax validation of all YAML files
- Verification of Flux resources using the Flux CLI
- Building and validation of all kustomize overlays
- Schema validation against Kubernetes resources and custom CRDs
- Dependency validation for custom resources like OnePasswordItem

### 2. `suspend-on-failure.yaml`

If the validation workflow fails, this secondary workflow:

- Creates a new branch with `.flux-suspend` markers in directories with kustomization files
- Opens a PR that, if merged, would suspend Flux reconciliation
- Provides guidance on how to recover from the validation failure

## Prerequisites

For the GitHub Actions to work properly, you need to:

1. Set up a `FLUX_GITHUB_TOKEN` secret in your repository settings with permissions to create branches and PRs.

## Local Validation

You can run the same validation locally before pushing changes:

```bash
# Make sure you have the required tools installed
# - flux CLI
# - kustomize
# - kubeconform
# - yq

# Run the validation script
./scripts/validate.sh
```

## Best Practices

1. **Always run validation before pushing**: Use the local validation script to catch issues early.
2. **Review validation failures carefully**: The error messages will help you understand what's wrong.
3. **Fix issues in the appropriate order**:
   - First fix CRDs and infrastructure components
   - Then fix secrets and credentials
   - Finally fix applications

4. **Maintain proper dependencies**: Ensure your kustomizations have appropriate `dependsOn` fields to control the application order.

## Troubleshooting

If you see validation failures related to OnePasswordItem resources, it likely means your dependency chain is incorrect. Make sure:

1. Your 1Password operator is deployed in the infrastructure layer
2. Your 1Password credentials are deployed in the secrets layer
3. Your applications with OnePasswordItem resources depend on both
