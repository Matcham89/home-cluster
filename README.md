# home-cluster
export BITWARDEN_KEY=
kubectl create secret generic bitwarden-access-token \
--namespace=kube-ops \
--from-literal=token=$BITWARDEN_KEY  \
--dry-run=client \
-o yaml > secret-bitwarden-token.yaml


# bootstrap/upgrade
export GITHUB_TOKEN=<gh-token>

flux bootstrap github \
  --token-auth \
  --owner=Matcham89 \
  --repository=home-cluster \
  --branch=main \
  --path=flux/clusters/dev \
  --personal
