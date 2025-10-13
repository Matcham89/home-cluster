# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a GitOps-managed Kubernetes home cluster using FluxCD for continuous deployment. The repository manages infrastructure components and applications through a declarative GitOps approach.

## Key Architecture Patterns

### GitOps Structure
- **FluxCD Bootstrap**: The cluster is bootstrapped via Flux pointing to the `clusters/dev` path
- **Base + Overlay Pattern**: Uses Kustomize base configurations in `flux/apps/base/` with environment-specific overlays in `flux/apps/dev/`
- **Flux Kustomization Objects**: Most components are deployed via Flux `Kustomization` resources defined in `ks.yaml` files

### Directory Structure
```
clusters/dev/           # Cluster entrypoint - Flux reads this
  infra-apps.yaml       # Points to flux/apps/dev (applications)

flux/
  apps/
    base/               # Base application manifests
      apps/             # Application workloads (kagent, kgateway, etc)
      kubeflow/         # Kubeflow pipelines
      kube-ops/         # Operational infrastructure
    dev/                # Dev environment overlays
      apps/             # App overlays with ks.yaml per component
      kubeflow/         # Kubeflow overlays
      kube-ops/         # Infrastructure overlays
  clusters/dev/         # Flux system configs
    flux-system/        # Core Flux components
```

### Component Dependencies
Applications declare dependencies using `spec.dependsOn` in Flux Kustomization resources:
- **external-secrets-operator** is typically a base dependency (pulls secrets from Bitwarden)
- **CRDs** must be deployed before operators (e.g., `kagent-crds` before `kagent`)
- Infrastructure components (`cert-manager`, `metal-lb`, `ingress-nginx-controller`) are deployed from `kube-ops`

## Key Technologies

### KAgent (Kubernetes AI Agent Framework)
- Custom CRD-based framework for deploying AI agents in Kubernetes
- Deployed via Helm from OCI registry: `oci://ghcr.io/kagent-dev/kagent/helm/kagent`
- Components organized into subdirectories:
  - `agents/`: Agent definitions (e.g., github-pusher, youtube scraper)
  - `mcps/`: MCP (Model Context Protocol) server configurations
  - `providers/`: AI provider configurations
  - `operator/`: Core KAgent operator deployment
  - `operations/`: Supporting resources (ingress, cloudflare tunnel)

### External Secrets
- Pulls secrets from Bitwarden using the External Secrets Operator
- Bootstrap requires creating a Bitwarden access token secret manually
- Secret references use `ExternalSecret` CRDs pointing to `ClusterSecretStore`

### Kubeflow Pipelines
- Large manifest files (2700+ lines) containing complete pipeline definitions
- Located in `flux/apps/base/kubeflow/pipeline/`
- Files like `namespace-scoped-resources.yaml` contain extensive ServiceAccount, Role, Deployment definitions

## Common Commands

### FluxCD Operations
```bash
# Bootstrap/upgrade the cluster
export GITHUB_TOKEN=<gh-token>
flux bootstrap github \
  --token-auth \
  --owner=Matcham89 \
  --repository=home-cluster \
  --branch=main \
  --path=clusters/dev \
  --personal

# Check Flux status
flux get kustomizations --watch

# Force reconciliation
flux reconcile kustomization <name> --with-source

# Check specific component status
flux get helmreleases -n <namespace>
```

### Kubectl Operations
```bash
# View Flux Kustomizations
kubectl get kustomizations -n flux-system

# Check application pods
kubectl get pods -n apps
kubectl get pods -n kubeflow
kubectl get pods -n kube-ops

# View KAgent resources
kubectl get agents -n apps
kubectl get remotemcpservers -n apps
kubectl get modelconfigs -n apps
```

### Secret Management
```bash
# Create Bitwarden access token secret (required for bootstrap)
kubectl create secret generic bitwarden-access-token \
  --namespace=kube-ops \
  --from-literal=key=$BITWARDEN_KEY \
  --dry-run=client \
  -o yaml > secret-bitwarden-token.yaml

# View external secrets
kubectl get externalsecrets -A
kubectl get clustersecretstores
```

## Development Workflow

### Adding/Modifying Applications
1. Update base manifests in `flux/apps/base/<component>/`
2. Add or modify overlay in `flux/apps/dev/<component>/`
3. Ensure `ks.yaml` exists in the dev overlay with proper dependencies
4. Commit and push - Flux will auto-reconcile (typically 1-10 minute intervals)

### Working with KAgent
- Agent definitions use the `Agent` CRD with declarative configurations
- System messages define agent behavior and capabilities
- Agents connect to MCP servers defined in `mcps/` directory
- Provider configurations (Anthropic, etc) are in `providers/` directory

### Kubeflow Pipeline Updates
- Pipeline manifests are large exported YAML files
- When updating pipelines, ensure all ServiceAccounts, Roles, and Deployments are included
- The namespace is typically `kubeflow`
- Changes reconcile via Flux Kustomization named `kubeflow-pipeline`

## Important Notes

### Git Workflow
- Main branch: `main`
- Recent commits show pattern: `deploy(<component>): <description>` or `fix(<component>): <description>`
- Flux automatically applies changes from Git to the cluster

### Namespace Organization
- `flux-system`: Core Flux components
- `apps`: Application workloads (kagent, kgateway)
- `kubeflow`: Kubeflow pipeline components
- `kube-ops`: Infrastructure operators (external-secrets, cert-manager, etc)

### Manifest Generation
When exporting large Kubernetes manifests (like Kubeflow pipelines), use:
```bash
kubectl get <resource> -n <namespace> -o yaml > <output-file>.yaml
```

### Troubleshooting
- Check Flux controller logs: `kubectl logs -n flux-system deploy/kustomize-controller`
- View reconciliation failures: `flux logs --level=error`
- Suspend auto-reconciliation: `flux suspend kustomization <name>`
- Resume auto-reconciliation: `flux resume kustomization <name>`
