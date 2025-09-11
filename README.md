# home-cluster

kubectl create secret generic bitwarden-access-token \
--namespace=external-secrets
--from-literal=key=$BITWARDEN_KEY  \
--dry-run=client \
-o yaml > secret-bitwarden-token.yaml
