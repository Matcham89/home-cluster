# home-cluster

test
GitOps repository for Kubernetes home cluster managed by Flux.

## What is Flux?

Flux is a GitOps operator that automatically syncs this Git repository to the Kubernetes cluster. Changes committed to this repo are automatically applied to the cluster. The cluster state is defined declaratively in Git - the single source of truth.

<https://fluxcd.io>

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

### Namespace Templates

Namespaces are templated in `flux/infra/` and consumed by apps in `flux/apps/dev/` using Kustomize components. Each app's kustomization sets the namespace name and includes the appropriate template.

**Available Templates:**

- `namespace` / `namespace-istio-enabled` - Istio ambient mode with gateway access
- `namespace-privileged` - Privileged pod security standard
- `namespace-istio-privileged` - Istio ambient mode + privileged security

**Example:**

```yaml
namespace: kube-ops
components:
  - ../../../infra/namespace-privileged
```

This DRY approach centralizes namespace configuration - security policies, Istio labels, and annotations are managed in one place.

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
- **Agent Substrate** (`kagent-dev/substrate`) - sandboxed actor runtime backing KAgent's WorkerPools. Has non-obvious, non-GitOps bootstrap requirements (CA/JWT secrets, RBAC) — see [docs/substrate-bootstrap-requirements.md](docs/substrate-bootstrap-requirements.md) before touching it.

## Backup and Recovery

**There is no automated backup of cluster data today.** Neither the Postgres layer nor the storage layer takes scheduled, restorable copies:

- The `postgres-cluster` CNPG Cluster (`flux/apps/base/databases/cluster/cluster.yaml`) has no `backup` / `barmanObjectStore` stanza, so WAL archiving and base backups are off and there is no `ScheduledBackup`.
- The Longhorn HelmRelease (`flux/apps/base/longhorn-system/helmrelease.yaml`) sets no `backupTarget`, so there is no object-storage/NFS backup target and no recurring snapshot or backup jobs.

What exists instead is **redundancy, not backup**. It protects against a node or disk failing, not against accidental deletion, data corruption, or a bad migration:

- Postgres runs 2 instances - primary plus a streaming-replication standby with automated failover.
- Longhorn keeps replicas of each volume across nodes and is tuned for power-outage recovery (`autoSalvage`, `autoDeletePodWhenVolumeDetachedUnexpectedly`, bounded replica rebuilds).

### Restore paths available today

| Failure | Recovery |
| --- | --- |
| Node loss, unexpected volume detach | CNPG fails over to the standby and Longhorn rebuilds replicas automatically. No manual restore step. |
| Accidental data loss, corruption, bad migration | No restorable copy exists. Recovery means either a logical dump taken manually **before** the event (`kubectl exec` + `pg_dump`) replayed with `psql`/`pg_restore`, or re-bootstrapping the cluster from `initdb` and re-seeding each consuming app (Authentik, n8n, agentdesktop) from scratch. |
| Point-in-time recovery | Not possible - without WAL archiving there is no recovery target to replay to. |

Adding real backups means configuring `spec.backup.barmanObjectStore` plus a `ScheduledBackup` on the CNPG cluster, and/or a Longhorn `backupTarget` with `RecurringJob`s, pointed at off-cluster storage. Until that exists, treat data in `postgres-cluster` as recoverable only as far back as the last manual dump.

## Quick Start

See [bootstrap/README.md](bootstrap/README.md) for installation instructions.
