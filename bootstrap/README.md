# Flux Bootstrap

## 1. Create Bitwarden Secret
```bash
export BITWARDEN_KEY=<your-token>
kubectl create secret generic bitwarden-access-token \
  --namespace=kube-ops \
  --from-literal=token=$BITWARDEN_KEY \
  --dry-run=client \
  -o yaml > secret-bitwarden-token.yaml
kubectl apply -f secret-bitwarden-token.yaml
```

## 2. Install Flux Operator (Minimal Bootstrap)
```bash
# Install minimal flux-operator without web UI to bootstrap GitOps
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --create-namespace
```

## 3. Apply FluxInstance
```bash
kubectl apply -f flux/clusters/dev/flux-instance.yaml
```

## 4. ResourceSet Takes Over
Once Flux reconciles, the ResourceSet in `flux/apps/base/flux-system/flux-operator-web/` will:
- Take over management of the flux-operator Helm release
- Add OAuth2/OIDC authentication configuration
- Deploy the HTTPRoute for Gateway access

**Note**: The manual Helm install (step 2) is only needed for initial bootstrap. After that, the ResourceSet manages everything via GitOps, including:
- Flux Operator upgrades
- Web UI configuration
- OAuth2 authentication
- Gateway routing