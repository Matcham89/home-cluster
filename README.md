# home-cluster

GitOps repository for Kubernetes home cluster managed by Flux.

## What is Flux?

Flux is a GitOps operator that automatically syncs this Git repository to the Kubernetes cluster. Changes committed to this repo are automatically applied to the cluster. The cluster state is defined declaratively in Git - the single source of truth.

https://fluxcd.io

## Structure

```
flux/
├── clusters/dev/          # Cluster-specific config
├── apps/
    ├── base/              # Base app configurations
    └── dev/               # Dev environment overlays
bootstrap/                 # Flux installation instructions
```

## Architecture

### Kustomization per Resource

Each service, operator, and configuration has its own Flux Kustomization (ks.yaml). This provides:

- **Granular control** - Each component reconciles independently
- **Isolation** - Failures in one component don't block others
- **Observability** - Clear visibility into each component's sync status
- **Dependency management** - Explicit ordering with `dependsOn` when needed

For example, cert-manager has separate kustomizations for the operator and its configuration, ensuring the operator is ready before applying certificates.

## Deployed Applications

### Infrastructure
- **Flux System** - GitOps operator
- **Longhorn** - Distributed storage
- **Cert Manager** - Certificate management
- **MetalLB** - Load balancer (192.168.1.201-209)
- **Metrics Server** - Resource metrics

### Service Mesh & Gateway
- **Istio** - Service mesh
- **Istio Gateway** - Ingress gateway
- **Kiali** - Service mesh observability

### Database
- **CNPG** - CloudNativePG operator

### Auth & Identity
- **Authentik** - Identity provider

### Monitoring
- **Kube Prometheus Stack** - Monitoring and alerting

### ML/AI
- **KAgent** - AI agent platform

## Quick Start

See [bootstrap/README.md](bootstrap/README.md) for installation instructions.
