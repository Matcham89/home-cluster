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

## 2. Install Flux Operator
```bash
helm install flux-operator oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --create-namespace
```

## 3. Apply FluxInstance
```bash
kubectl apply -f flux/clusters/dev/flux-instance.yaml
```