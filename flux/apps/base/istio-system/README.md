# Istio

Service mesh deployed in **ambient mode** (no sidecars). All app pods communicate via ztunnel (L4 mTLS) with optional waypoint proxies (L7).

## Components

| Component | Chart | Version |
|---|---|---|
| `istio-base` | `base` | 1.29.1 |
| `istiod` | `istiod` | 1.29.1 |
| `istio-cni` | `cni` | 1.29.1 |
| `ztunnel` | `ztunnel` | 1.29.1 |

All 4 versions must stay in sync. Renovate will propose updates — bump all together.

## Architecture

```
Internet → Cloudflare → cloudflared (2 replicas, istio-system)
         → istio-gateway (LoadBalancer 192.168.1.201, gatewayClassName: istio)
         → HBONE (port 15008) → waypoint proxy (per namespace)
         → HBONE → backend pod (via ztunnel)
```

Traffic is **mTLS end-to-end**. Every connection in ztunnel logs shows `dst.addr=<pod>:15008` (HBONE) with `src.identity` and `dst.identity` SPIFFE certificates.

The `istio-gateway` pod has `istio.io/dataplane-mode: none` and `sidecar.istio.io/inject: false` — it manages its own Envoy proxy and speaks HBONE directly. It does **not** go through ztunnel.

## Namespace Enrollment

Two infra components control ambient enrollment:

| Component | Labels Added | Used By |
|---|---|---|
| `infra/namespace-istio-enabled` | `istio.io/dataplane-mode: ambient` + `istio.io/use-waypoint: waypoint` + `istio-gateway-access: "true"` | App namespaces (restricted PSS) |
| `infra/namespace-istio-privileged` | Same + `pod-security.kubernetes.io/enforce: privileged` | System/storage namespaces needing privileged pods |
| `infra/namespace-privileged` | `istio.io/dataplane-mode: none` + privileged PSS | Infra namespaces excluded from mesh (flux-system, kube-ops, metrics-server) |
| `infra/namespace` | `istio.io/dataplane-mode: none` | External-services namespace |

System namespaces (kube-system, kube-public, kube-node-lease, default) have `istio.io/dataplane-mode: none` applied via kubectl (not managed by Flux).

## Waypoint Proxies

Each enrolled namespace has a waypoint deployed via `flux/apps/base/waypoint/waypoint.yaml`:

```yaml
gatewayClassName: istio-waypoint
listeners:
- name: mesh
  port: 15008
  protocol: HBONE
```

The `istio.io/use-waypoint: waypoint` namespace label tells ztunnel to route L7 traffic through the waypoint instead of directly pod-to-pod. Waypoint pods themselves have `istio.io/dataplane-mode: none` — they are the proxy, not a mesh participant.

## Security

### PeerAuthentication
`security/peer-authentication.yaml` enforces **STRICT mTLS mesh-wide** (applied in root namespace `istio-system` with no selector). This means all pod-to-pod traffic must use mTLS.

The gateway is excluded because it has `istio.io/dataplane-mode: none` and manages its own HBONE connections.

### AuthorizationPolicies
Policies live **co-located with each app** (`flux/apps/base/<app>/security/authorization-policy.yaml`). They follow a consistent pattern: allow ingress from `istio-system` (gateway/cloudflared) and from the app's own namespace (internal service-to-service).

The only AuthorizationPolicy remaining in `istio-system/security/` is `authz-kiali.yaml` — Kiali lives in `istio-system` so it stays here.

### Gateway Access Control
The `istio-gateway` only routes to namespaces with the label `istio-gateway-access: "true"` (set by the namespace infra components). HTTPRoutes use ReferenceGrants (`istio/referencegrants/`) to permit cross-namespace backend references.

## Ingress Flow

```
cloudflared → http://192.168.1.201 (istio-gateway ClusterIP)
            → HTTPRoute (matched by hostname *.kubegit.com)
            → ReferenceGrant (permits cross-namespace backend)
            → Service → waypoint (HBONE) → pod (HBONE)
```

All Cloudflare tunnel routes must point to `http://192.168.1.201` (the istio-gateway LoadBalancer IP), **not** to individual service LoadBalancer IPs. Routing around the gateway bypasses mTLS and AuthorizationPolicies.

## Verifying Ambient Enrollment

```bash
# All app pods should show ambient.istio.io/redirection: enabled
kubectl get pods -A -o json | jq -r '
  .items[] |
  select(.metadata.annotations["ambient.istio.io/redirection"] != null) |
  "\(.metadata.namespace)/\(.metadata.name)"' | sort

# Verify HBONE (mTLS) in ztunnel logs — every connection should show dst.addr=<ip>:15008
kubectl logs -n istio-system -l app=ztunnel --tail=50 | grep "dst.addr"
```

Expected exclusions (no ambient annotation):
- Waypoint pods — `istio.io/dataplane-mode: none`
- ztunnel, CNI, istiod, istio-gateway — infrastructure pods
- Node exporter DaemonSets — `hostNetwork: true`, cannot be enrolled

## Troubleshooting

### 502 Bad Gateway after namespace enrolled in ambient

**Check 1:** Network policy label. Gateway API creates pods with label `app.kubernetes.io/name: istio-gateway` (not the legacy `istio: ingressgateway`). Update any NetworkPolicy ingress rules accordingly.

**Check 2:** Cloudflare tunnel routing. Ensure the route points to `http://192.168.1.201` (istio-gateway), not to a service's own LoadBalancer IP.

### STRICT mTLS breaking gateway → backend traffic

The gateway pod has `istio.io/dataplane-mode: none` and sends plain HTTP unless waypoint proxies are deployed. With STRICT mTLS, ztunnel rejects non-HBONE traffic.

**Fix:** Ensure waypoint proxies are deployed in each namespace (`istio.io/use-waypoint: waypoint` namespace label + waypoint Gateway resource). istiod then configures the gateway's Envoy to use HBONE to reach waypoints.

### Checking mTLS identity on a live connection

```bash
# Inspect ztunnel access log for a specific namespace
kubectl logs -n istio-system -l app=ztunnel --tail=200 | grep "<namespace>"
# Look for: src.identity="spiffe://cluster.local/ns/<ns>/sa/<sa>"
#           dst.identity="spiffe://cluster.local/ns/<ns>/sa/<sa>"
#           dst.addr=<pod-ip>:15008  ← HBONE = mTLS tunnel
```

### Upgrading Istio

All 4 components (`base`, `istiod`, `cni`, `ztunnel`) must be upgraded together. Update the `version:` field in all 4 HelmRelease files in `istio/operator/`. Renovate proposes these individually — always batch them into one PR.
