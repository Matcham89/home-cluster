# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Flux CD v2 GitOps repository for a home Kubernetes cluster. Git is the source of truth; Flux reconciles the cluster state from this repo. No build system — all changes are applied by pushing to `main`.

## Common Operational Commands

```bash
# Check Flux reconciliation status
flux get kustomizations -A
flux get helmreleases -A

# Force immediate reconciliation
flux reconcile kustomization cluster-apps --with-source
flux reconcile helmrelease <name> -n <namespace>

# Validate manifests before pushing
flux build kustomization cluster-apps --path ./flux/apps/dev --dry-run
kubectl kustomize flux/apps/base/<app>  # Preview rendered output

# Check why something isn't reconciling
flux logs --follow --level=error
kubectl describe kustomization <name> -n flux-system

# Verify Istio ambient enrollment
kubectl get pods -A -o json | jq -r '.items[] | select(.metadata.annotations["ambient.istio.io/redirection"] != null) | "\(.metadata.namespace)/\(.metadata.name)"' | sort
kubectl logs -n istio-system -l app=ztunnel --tail=50 | grep "dst.addr"
```

## Architecture: Three-Layer GitOps

```
clusters/dev/           ← Flux entrypoint (FluxInstance + root Kustomization)
apps/
  base/                 ← Cluster-agnostic Kubernetes manifests (HelmReleases, CRDs, policies)
  dev/                  ← Flux Kustomization resources (ks.yaml) that reference base paths
infra/                  ← Reusable Kustomize Components for namespace templates
```

**How it works:**
1. `clusters/dev/cluster-apps.yaml` — root Flux Kustomization, sources `./flux/apps/dev`
2. `clusters/dev/flux-instance.yaml` — FluxInstance managing Flux Operator self-upgrade; syncs from `github.com/Matcham89/home-cluster` main branch at 1-minute intervals
3. `apps/dev/**/ks.yaml` — each is a Flux `Kustomization` resource pointing to a path in `apps/base/`
4. `apps/base/**/` — contains the actual Kubernetes manifests (HelmReleases, ConfigMaps, policies, etc.)

**File naming conventions:**
- `ks.yaml` — Flux Kustomization resource (lives in `apps/dev/`)
- `helmrelease-*.yaml` — HelmRelease resource (lives in `apps/base/`)
- `kustomization.yaml` — Kustomize resource aggregation (both layers)

## Application Directory Pattern

Each application is split across two layers with a consistent structure:

```
apps/base/<namespace>/<app>/
├── app/                          # Main workload manifests
│   ├── deployment.yaml (or helmrelease-*.yaml)
│   ├── service.yaml
│   └── servicemonitor.yaml       # if exposing metrics
├── security/
│   ├── authorization-policy.yaml # Istio AuthZ (required for ambient namespaces)
│   └── peer-authentication.yaml  # only if overriding STRICT (e.g., webhook exceptions)
├── secrets/
│   └── external-secret.yaml      # pulls from 1Password via ESO
└── kustomization.yaml

apps/dev/<namespace>/
├── kustomization.yaml            # references infra/ component for namespace config
├── app/ks.yaml
├── security/ks.yaml
├── secrets/ks.yaml
├── waypoint/ks.yaml              # deploys Istio waypoint (required for ambient namespaces)
├── network-policies/ks.yaml
├── limit-ranges/ks.yaml
└── resource-quotas/ks.yaml
```

Each `apps/dev/<namespace>/` directory gets its namespace labels/PSS via a `components:` entry in its `kustomization.yaml` referencing one of the `infra/` components.

## Adding a New Application

1. Create `apps/base/<namespace>/<app>/` with the subdirectory structure above
2. Create matching `apps/dev/<namespace>/` Flux Kustomizations — one `ks.yaml` per subdirectory
3. Set `dependsOn` in each `ks.yaml` as needed (e.g., secrets must exist before app, cnpg before apps using postgres)
4. Add the namespace `kustomization.yaml` with appropriate infra component
5. To expose externally: add an HTTPRoute to `apps/base/ingress/httproutes/` and a ReferenceGrant to `apps/base/ingress/referencegrants/`

**ks.yaml template:**
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app <name>
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  interval: 1h
  path: ./flux/apps/base/<path>
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: <namespace>
  timeout: 5m
  prune: true
  wait: true
  dependsOn:
    - name: <dependency>
```

## Namespace Infra Components

Two active Kustomize Components in `infra/` — include via `components:` in a namespace's `kustomization.yaml`:

| Component | PSS | Use For |
|---|---|---|
| `namespace` | restricted | Regular app namespaces (authentik, n8n, kagent, rundeck, databases, 1password) |
| `namespace-privileged` | privileged | System/storage namespaces (longhorn-system, monitoring, storage, kgateway-system) |

## Ingress Architecture

No service mesh. Traffic enters via Cloudflare Tunnel → `ingress-gateway` (agentgateway GatewayClass, IP `192.168.1.201`) → HTTPRoute → pod.

- **Ingress gateway**: `apps/base/ingress/gateway/gateway.yaml` — agentgateway on port 80, hostname `*.kubegit.com`, MetalLB IP `192.168.1.201`
- **cloudflared**: `apps/base/ingress/tunnel/` — 2-replica Deployment pulling tunnel token from ExternalSecret
- **HTTPRoutes**: `apps/base/ingress/httproutes/` — one route per app (authentik, grafana, kagent, longhorn, n8n, rundeck)
- **ReferenceGrants**: `apps/base/ingress/referencegrants/` — one per target namespace allowing HTTPRoutes in `ingress` to reach backend Services
- All Cloudflare Zero Trust routes must point to `http://192.168.1.201` (the ingress-gateway LoadBalancer IP)

## Secret Management

Secrets are managed via **External Secrets Operator (ESO)** pulling from **1Password**. The 1Password Connect operator runs in the `1password` namespace.

- `ExternalSecret` resources live in `apps/base/<app>/secrets/`
- They reference a `ClusterSecretStore` (1Password) and map item fields to Kubernetes secret keys
- The secrets `ks.yaml` should have `dependsOn` set to the 1password/ESO Kustomization and `wait: true` so downstream app deployments only start after secrets are available

## External Services

Off-cluster services (running at `192.168.1.100`) are exposed in-cluster via **EndpointSlice** resources in the `external-services` namespace. This allows in-cluster apps to reach them by Service name without leaving the cluster DNS.

Key external services exposed this way:
- PostgreSQL `:5432` — used by authentik, n8n (via `cnpg-system` cluster or direct)
- Qdrant `:6333/6334` — vector database
- SeaweedFS `:8333` (S3), `:8888` (Filer), `:9333` (Master)
- Ollama `:11434` — local LLM inference

## Network Policies

Reusable network policies live in `apps/base/network-policies/<namespace>/`. The pattern is:
- Default deny-all ingress/egress as the base
- Allow DNS (port 53), Istio ztunnel, and Prometheus scraping
- App-specific rules added per namespace (e.g., allow postgres egress for apps using CNPG)

## kgateway / Claude AI Gateways

`apps/base/kgateway-system/` hosts a multi-gateway architecture for Claude API access with per-model gateways (Sonnet on 8091, Opus on 8092, Haiku on 8093). Each gateway has a hardcoded backend — the model cannot be overridden by the client. See `CLAUDE-ARCHITECTURE.md` in that directory for full details.

## Monitoring

- Prometheus scrapes via `PodMonitor`/`ServiceMonitor` resources with label `release: kube-prometheus-stack`
- Grafana dashboards auto-discovered via ConfigMap label `grafana_dashboard: "1"`
- The monitoring namespace is **enrolled in Istio ambient** (`namespace-istio-privileged` component). Admission webhooks (otel-operator, prometheus-operator) use scoped `PERMISSIVE` PeerAuthentication so kube-apiserver can reach them — all other traffic stays STRICT.

## Key Dependencies (install order via `dependsOn`)

```
cert-manager → (almost everything with TLS)
cnpg-system  → (apps using PostgreSQL: authentik, n8n, etc.)
istio-operator → istio-gateway → (all app namespaces with HTTPRoutes)
kube-prometheus-stack → (anything with ServiceMonitors)
1password → external-secrets → (all apps with ExternalSecrets)
```
