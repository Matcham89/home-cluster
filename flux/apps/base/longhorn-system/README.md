# Longhorn

Distributed block storage for Kubernetes. Deployed via Helm v1.11.1 from `https://charts.longhorn.io`.

## Key Configuration

| Setting | Value | Reason |
|---|---|---|
| `guaranteedInstanceManagerCPU` | `5%` | Reduced from default 12% — instance manager pods were exceeding CPU limits (requests 954m > limit 500m) |
| `storageOverProvisioningPercentage` | `200%` | Allows scheduling up to 2× physical capacity; required to support current volumes with 30% reserved storage |

Longhorn runs in **Istio ambient mesh** (`namespace-istio-privileged` component). The admission webhook serves on port 9502 from the `longhorn-manager` DaemonSet pods.

## Istio Integration

Longhorn uses `namespace-istio-privileged` (privileged pod security + ambient mesh + waypoint). The `longhorn-system` namespace is **excluded from the Longhorn admission webhook** scope is not needed because the webhook is served by the managers themselves.

The waypoint proxy handles L7 traffic to `longhorn-ui`. The AuthorizationPolicy (`security/authorization-policy.yaml`) allows ingress only from `istio-system` (gateway) and `longhorn-system` (internal).

## Troubleshooting

### Longhorn manager crash loop: `failed calling webhook "mutator.longhorn.io": EOF`

This is a bootstrapping deadlock — the managers need to start to serve the webhook, but the webhook is called during manager startup.

**Cause:** All manager pods restarted simultaneously (e.g. after `kubectl rollout restart`) with no running pods to back the webhook service endpoints.

**Fix:**
```bash
# 1. Patch webhook to exclude longhorn-system so managers can start without calling themselves
kubectl patch mutatingwebhookconfiguration longhorn-webhook-mutator --type='json' \
  -p='[{"op":"add","path":"/webhooks/0/namespaceSelector","value":{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"NotIn","values":["longhorn-system"]}]}}]'

kubectl patch validatingwebhookconfiguration longhorn-webhook-validator --type='json' \
  -p='[{"op":"add","path":"/webhooks/0/namespaceSelector","value":{"matchExpressions":[{"key":"kubernetes.io/metadata.name","operator":"NotIn","values":["longhorn-system"]}]}}]'

# 2. Restart managers
kubectl delete pods -n longhorn-system -l app=longhorn-manager

# 3. Wait for all 3 managers to be 2/2 Running
kubectl get pods -n longhorn-system -l app=longhorn-manager -w

# 4. Remove the temporary exclusion
kubectl patch mutatingwebhookconfiguration longhorn-webhook-mutator --type='json' \
  -p='[{"op":"remove","path":"/webhooks/0/namespaceSelector"}]'

kubectl patch validatingwebhookconfiguration longhorn-webhook-validator --type='json' \
  -p='[{"op":"remove","path":"/webhooks/0/namespaceSelector"}]'
```

> Do NOT just delete the webhook configurations — Longhorn recreates them immediately via a running manager, and if no manager is running the config persists from a previous run and blocks startup.

### PVC stuck in Terminating with `kubernetes.io/pvc-protection` finalizer

Usually caused by the Longhorn admission webhook being unreachable (see above). Fix the crash loop first, then:

```bash
kubectl patch pvc <name> -n <namespace> -p '{"metadata":{"finalizers":null}}'
```

### Flux kustomizations failing with Longhorn webhook EOF

`n8n`, `rundeck`, and other apps with Longhorn PVCs will show dry-run failures if the Longhorn webhook is down. These resolve automatically once the managers recover.

### Checking volume health

```bash
kubectl get volumes -n longhorn-system
kubectl get replicas -n longhorn-system | grep -v Running
```
