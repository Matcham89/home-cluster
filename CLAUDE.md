# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is a GitOps-managed Kubernetes home cluster using FluxCD for continuous deployment. The repository manages infrastructure components and applications through a declarative GitOps approach.

## Key Architecture Patterns

### GitOps Structure
- **FluxCD Bootstrap**: The cluster is bootstrapped via Flux pointing to the `clusters/dev` path (defined in `flux/clusters/dev/infra-apps.yaml`)
- **Base + Overlay Pattern**: Uses Kustomize base configurations in `flux/apps/base/` with environment-specific overlays in `flux/apps/dev/`
- **Flux Kustomization Objects**: Components are deployed via Flux `Kustomization` resources defined in `ks.yaml` files
- **Single Environment**: Currently only `dev` environment exists; no production environment

### Directory Structure
```
flux/
  clusters/dev/          # Flux bootstrap entrypoint
    infra-apps.yaml      # Points to flux/apps/dev (triggers all app deployments)
    flux-system/         # Core Flux components (gotk-sync, gotk-components)
  apps/
    base/                # Base application manifests (no cluster-specific config)
      apps/              # Application workloads (kagent, kgateway, minio)
      kube-ops/          # Infrastructure operators (external-secrets, cert-manager, ingress-nginx, metal-lb)
    dev/                 # Dev environment overlays and ks.yaml deployment configs
      apps/              # App overlays with ks.yaml per component
      kube-ops/          # Infrastructure overlays with ks.yaml per component
  infra/                 # Namespace definitions
```

### Component Dependencies
Applications declare dependencies using `spec.dependsOn` in Flux Kustomization resources. Critical dependency chain:
1. **cert-manager-config** (base infrastructure)
2. **external-secrets-operator** (depends on cert-manager-config)
3. **external-secrets-store** (depends on external-secrets-operator, includes health checks)
4. **Application CRDs** (e.g., `kagent-crds`, `kgateway-crds`) depend on external-secrets-operator
5. **Application operators** (e.g., `kagent`, `kgateway`) depend on their respective CRDs

Infrastructure deployment order from `kube-ops`:
- cert-manager → external-secrets → metal-lb → ingress-nginx-controller → tailscale

## Key Technologies

### KAgent (Kubernetes AI Agent Framework)
- Custom CRD-based framework for deploying AI agents in Kubernetes
- Deployed via Helm from OCI registry: `oci://ghcr.io/kagent-dev/kagent/helm/kagent` (current version: 0.6.18)
- Built-in agents include: k8s-agent, kgateway-agent, helm-agent, observability-agent, istio-agent (see `operator/helmrelease.yaml` for full list)
- Components organized into subdirectories:
  - `agents/`: Custom agent definitions using `Agent` CRD (e.g., github-pusher, youtube scraper)
  - `mcps/`: MCP (Model Context Protocol) server configurations using `RemoteMCPServer` CRD
  - `providers/`: AI provider configurations (e.g., `claude.yaml` for Anthropic)
  - `operator/`: Core KAgent operator deployment (Helm chart + values)
  - `operations/`: Supporting resources (ingress, cloudflare tunnel, shadow service)
- **Agent Structure**: Agents use `spec.declarative` with `modelConfig`, `systemMessage`, `tools`, and optional `a2aConfig` for Agent-to-Agent communication
- **Tool Integration**: Agents connect to MCP servers by referencing `RemoteMCPServer` resources and specifying `toolNames`

### KGateway (Kubernetes Gateway API for AI)
- Kubernetes-native API gateway based on Gateway API standard
- Provides **AgentGateway** capabilities for routing to AI agents and MCP servers
- Deployed via Helm from OCI registry (similar to KAgent)
- Key features:
  - **Dynamic MCP Discovery**: Uses Kubernetes label selectors to find MCP servers (`kagent.dev/mcp-service=true`)
  - **Protocol Translation**: Handles SSE (Server-Sent Events) required by MCP
  - **Multi-backend Aggregation**: Can route to multiple MCP servers
- Components:
  - `crds/`: Gateway API CRDs
  - `operator/`: KGateway controller and agentgateway deployment
  - `operations/`: Gateway resources (gateway.yaml, httproute.yaml, backends.yaml)
- **Routing Architecture**: Client → Gateway (LoadBalancer:8080) → HTTPRoute (path matching) → Backend (label selector) → Service → Pod
- See `flux/apps/base/apps/kgateway/README.md` for comprehensive KGateway documentation

### External Secrets
- Pulls secrets from Bitwarden Secrets Manager using the External Secrets Operator
- Bootstrap requires manually creating `bitwarden-access-token` secret in `kube-ops` namespace
- Uses `ClusterSecretStore` named `bitwarden-secretsmanager` that connects to Bitwarden SDK server at `bitwarden-sdk-server.kube-ops.svc.cluster.local:9998`
- External secrets reference the ClusterSecretStore and sync to Kubernetes secrets
- **Health Checks**: The `external-secrets-store` Kustomization uses `healthCheckExprs` to verify ClusterSecretStore is Ready before proceeding

### Storage (MinIO)
- S3-compatible object storage deployed in the cluster
- Includes custom StorageClass definition
- Deployed via Helm chart in `flux/apps/base/apps/minio/`

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
kubectl get pods -n kube-ops

# View KAgent resources
kubectl get agents -n apps
kubectl get remotemcpservers -n apps
kubectl get modelconfigs -n apps

# View KGateway resources
kubectl get gateway -n apps
kubectl get httproute -n apps
kubectl get backend -n apps

# Check services with MCP label (for KGateway discovery)
kubectl get svc -n apps -l kagent.dev/mcp-service=true
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
3. Create or update `ks.yaml` in the dev overlay with:
   - `path`: pointing to base directory
   - `dependsOn`: list of prerequisite Kustomizations (with namespace if in different namespace)
   - `targetNamespace`: destination namespace
   - `interval`: reconciliation interval (typically 1h)
4. Commit and push - Flux will auto-reconcile (interval: 10m for cluster-apps, component-specific intervals for others)

### Working with KAgent
- Agent definitions use the `Agent` CRD with `spec.declarative`
- **System messages** define agent behavior via `systemMessage` field (can be multi-line YAML)
- **Tools**: Agents connect to MCP servers by referencing `RemoteMCPServer` resources and listing specific `toolNames`
- **A2A Config**: Define agent skills using `a2aConfig.skills` to enable Agent-to-Agent discovery
- **Providers**: Model configurations reference provider configs in `providers/` directory (e.g., `claude.yaml`)
- When creating new agents, ensure corresponding MCP servers and tools are defined first

### Working with KGateway
- **Adding MCP routes**: Create HTTPRoute pointing to Backend resource
- **Backend discovery**: Backends use label selectors to find services (e.g., `kagent.dev/mcp-service=true`)
- **Service requirements**: MCP services must have:
  - Label: `kagent.dev/mcp-service=true`
  - Port with `appProtocol: kgateway.dev/mcp`
  - Optional annotation: `kagent.dev/mcp-service-path` (default: /mcp)
- **Testing**: Use MCP Inspector (`npx @modelcontextprotocol/inspector@0.16.2`) with Streamable HTTP transport
- Gateway exposed at `192.168.1.53:8080` via LoadBalancer

## Important Notes

### Git Workflow
- Main branch: `main`
- Recent commits show pattern: `deploy(<component>): <description>` or `fix(<component>): <description>`
- Flux automatically applies changes from Git to the cluster

### Namespace Organization
- `flux-system`: Core Flux components (kustomize-controller, source-controller, helm-controller)
- `apps`: Application workloads (kagent agents, kgateway gateway, minio)
- `kube-ops`: Infrastructure operators (external-secrets, cert-manager, metal-lb, ingress-nginx, tailscale, bitwarden-sdk-server)

### Troubleshooting

#### Flux Issues
- Check Flux controller logs: `kubectl logs -n flux-system deploy/kustomize-controller`
- View reconciliation failures: `flux logs --level=error`
- Suspend auto-reconciliation: `flux suspend kustomization <name>`
- Resume auto-reconciliation: `flux resume kustomization <name>`
- Check specific Kustomization status: `kubectl describe kustomization <name> -n flux-system`

#### External Secrets Issues
- Verify ClusterSecretStore is Ready: `kubectl get clustersecretstore bitwarden-secretsmanager -o yaml`
- Check ExternalSecret sync status: `kubectl get externalsecret -n <namespace>`
- View bitwarden-sdk-server logs: `kubectl logs -n kube-ops -l app=bitwarden-sdk-server`

#### KGateway/MCP Issues
- Check Gateway status: `kubectl get gateway agentgateway -n apps`
- View agentgateway logs: `kubectl logs -n apps -l app.kubernetes.io/name=agentgateway --tail=50`
- Verify Backend resolution: `kubectl describe backend <backend-name> -n apps`
- HTTPRoute status: `kubectl describe httproute <route-name> -n apps`
- Remember: curl returns 406 for MCP endpoints (expected - requires SSE support)
