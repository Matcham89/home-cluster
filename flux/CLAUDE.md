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
clusters/dev/           ← Flux entrypoint; points at apps/dev
apps/
  base/                 ← Cluster-agnostic Kubernetes manifests (HelmReleases, CRDs, policies)
  dev/                  ← Flux Kustomization resources (ks.yaml) that reference base paths
infra/                  ← Reusable Kustomize Components for namespace templates
```

**How it works:**
1. `clusters/dev/cluster-apps.yaml` — root Flux Kustomization, sources `./flux/apps/dev`
2. `apps/dev/**/ks.yaml` — each is a Flux `Kustomization` resource pointing to a path in `apps/base/`
3. `apps/base/**/` — contains the actual Kubernetes manifests (HelmReleases, ConfigMaps, policies, etc.)

**File naming conventions:**
- `ks.yaml` — Flux Kustomization resource (lives in `apps/dev/`)
- `helmrelease-*.yaml` — HelmRelease resource (lives in `apps/base/`)
- `kustomization.yaml` — Kustomize resource aggregation (both layers)

## Adding a New Application

1. Create `apps/base/<namespace>/<app>/` with: `kustomization.yaml`, `helmrepository.yaml`, `helmrelease-<app>.yaml`
2. Create `apps/dev/<namespace>/ks.yaml` (or add to existing) with a Flux Kustomization referencing the base path
3. Set `dependsOn` in the ks.yaml if the app requires other components (e.g., cert-manager, cnpg)
4. Choose a namespace infra component (see below)

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

Four reusable Kustomize Components in `infra/` — include via `components:` in a namespace's `kustomization.yaml`:

| Component | Istio | PSS | Use For |
|---|---|---|---|
| `namespace-istio-enabled` | ambient + waypoint | restricted | Regular app namespaces |
| `namespace-istio-privileged` | ambient + waypoint | privileged | Storage/system apps needing privilege |
| `namespace-privileged` | excluded | privileged | Infra namespaces (flux-system, kube-ops) |
| `namespace` | excluded | restricted | External services / no-mesh namespaces |

## Istio Ambient Mode

No sidecars. All mTLS is via ztunnel (L4) + optional waypoint proxies (L7).

- **Every enrolled namespace** needs a waypoint deployed (`apps/base/waypoint/waypoint.yaml` included via kustomization)
- **AuthorizationPolicies** live co-located with each app in `apps/base/<app>/security/`
- **Ingress flow:** Cloudflare → cloudflared → `http://192.168.1.201` (istio-gateway) → HTTPRoute → ReferenceGrant → waypoint → pod
- All Cloudflare tunnel routes must point to the istio-gateway IP (`192.168.1.201`), not to individual service IPs
- STRICT mTLS is enforced cluster-wide; do not route around the gateway

**Istio upgrades:** All 4 components (`base`, `istiod`, `cni`, `ztunnel`) must be bumped together in one PR. They all pin to the same version (currently 1.29.1).

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
```
