# Flux Bootstrap

## Version pinning: which "Flux version"?

This repo pins two independent version streams. Don't confuse them:

| Component | Line | Pinned in |
| --- | --- | --- |
| flux-operator (Helm chart) | `0.x` | `bootstrap/README.md` (step 2) **and** `flux/apps/base/flux-system/flux-operator/flux-operator-config.yaml` (`OCIRepository.spec.ref.semver`) |
| Flux CD toolkit distribution (source/kustomize/helm/notification controllers) | `2.x` | `flux/clusters/dev/flux-instance.yaml` (`spec.distribution.version`) |

The operator pin must be kept in sync between the bootstrap command below and the
ResourceSet's `OCIRepository`, otherwise the version installed at bootstrap drifts
away from the version GitOps converges on.

## 1. Create Bitwarden Secret

```bash
export BITWARDEN_KEY="" #access token
kubectl create secret generic bitwarden-access-token \
  --namespace=kube-ops \
  --from-literal=token=$BITWARDEN_KEY \
  --dry-run=client \
  -o yaml > secret-bitwarden-token.yaml
kubectl apply -f secret-bitwarden-token.yaml
rm secret-bitwarden-token.yaml
```

## 1b. Define 1password authentication

```bash
kubectl create secret generic op-credentials \
  --from-file=config.json=1password-credentials.json
```

## 2. Install Flux Operator (Minimal Bootstrap)

```bash
# Install minimal flux-operator without web UI to bootstrap GitOps
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --version=0.60.0 \
  --namespace flux-system \
  --create-namespace
```

## 3. Apply FluxInstance

```bash
kubectl apply -f flux/clusters/dev/flux-instance.yaml
```

## 4. ResourceSet Takes Over

Once Flux reconciles, the ResourceSet in `flux/apps/base/flux-system/flux-operator/` will:

- Take over management of the flux-operator Helm release
- Add OAuth2/OIDC authentication configuration
- Deploy the HTTPRoute for Gateway access

**Note**: The manual Helm install (step 2) is only needed for initial bootstrap. After that, the ResourceSet manages everything via GitOps, including:

- Flux Operator upgrades
- Web UI configuration
- OAuth2 authentication
- Gateway routing

The ResourceSet pins the same operator version as step 2. To upgrade the operator,
change **both** the `--version` above and `OCIRepository.spec.ref.semver` in
`flux/apps/base/flux-system/flux-operator/flux-operator-config.yaml`.

---

## Disaster Recovery

### Full Cluster Rebuild

Follow steps 1-3 above. Wait 2-5 minutes for ResourceSet to reconcile and deploy the web UI.

**Verify:**

```bash
kubectl get helmrelease flux-operator -n flux-system
kubectl get pods -n flux-system
```

### Operator Pod Deleted

Auto-recreates via deployment (managed by Helm/ResourceSet).

### FluxInstance Deleted

```bash
kubectl apply -f flux/clusters/dev/flux-instance.yaml
```

### ResourceSet Deleted

Auto-recreates from Kustomization `flux-system-flux-operator` in Git.
