# Authentik Terraform

Manages Authentik configuration as code: OAuth2 providers, applications, and groups.

Running `terraform apply` fully restores Authentik config after a database loss — no manual UI work.

## What this manages

| Resource | Type | Notes |
|---|---|---|
| `flux-kubegit-com` | OAuth2 Provider + Application | Flux Web UI |
| `kagent-kubegit-com` | OAuth2 Provider + Application | Kagent (via oauth2-proxy) |
| `grafana-kubegit-com` | OAuth2 Provider + Application | Grafana generic OAuth |
| `kiali-kubegit-com` | OAuth2 Provider + Application | Kiali OIDC |
| `flux-admins` | Group | Bound to `flux-web-admin` ClusterRole |
| `Grafana Admins` | Group | Maps to Grafana Admin role |
| `Grafana Editors` | Group | Maps to Grafana Editor role |

Client credentials are read directly from existing cluster secrets — no secrets are stored in this repo or in Terraform state in plaintext.

## Prerequisites

- `terraform` >= 1.5
- `kubectl` configured and pointing at the cluster (to read client secrets)
- An Authentik API token (see below)

## Getting an Authentik API Token

1. Log in to Authentik at `https://authentik.kubegit.com`
2. Go to **Admin Interface** → **Directory** → **Tokens and App Passwords**
3. Click **Create** → Token type: **API Token**
4. Copy the token value

## First Apply

```bash
cd terraform/authentik

# Initialise providers
terraform init

# Set your API token (never commit this)
export TF_VAR_authentik_token="<your-token-here>"

# Preview changes
terraform plan

# Apply
terraform apply
```

The `kubernetes` provider reads client secrets directly from the cluster using your current kubeconfig context. If you need a specific context:

```bash
export TF_VAR_kube_context="my-cluster-context"
```

## Recovering after a database loss

This is the primary reason this Terraform exists. After Authentik is back up with a fresh database:

1. Generate a recovery token for `akadmin`:

```bash
kubectl exec -n authentik deploy/authentik-server -- ak create_recovery_key 86400 akadmin
```

   Open the printed URL in your browser to log in as `akadmin`, then create a normal admin user.

2. Create a new API token (see above).
3. Run:

```bash
export TF_VAR_authentik_token="<new-token>"
terraform apply
```

All four applications and groups are recreated in ~30 seconds. No k8s secrets need to change since the same client IDs and secrets are reused.

## State

Terraform state is stored locally in `terraform.tfstate`. This file is gitignored.

If you want shared state (e.g. for multiple machines), configure a backend in `providers.tf`:

```hcl
# Example: Kubernetes secret backend
terraform {
  backend "kubernetes" {
    secret_suffix    = "authentik-tfstate"
    namespace        = "authentik"
    config_path      = "~/.kube/config"
  }
}
```

## Troubleshooting

**`Error: flow not found` on plan**
The default Authentik flows use fixed slugs. Verify the slugs exist at:
Admin Interface → Flows & Stages → Flows

Expected slugs:
- `default-provider-authorization-implicit-consent`
- `default-invalidation-flow`

**`Error: certificate not found`**
The signing certificate is looked up by name. Verify it exists at:
Admin Interface → System → Certificates — should be `authentik Self-signed Certificate`.

**App redirects fail after apply**
Each app's redirect URI is set to `strict` matching. If a redirect fails, check the Authentik event log (Admin Interface → Events) for the exact URI the app is sending and update `allowed_redirect_uris` to match.

Correct URIs (as confirmed working):
- Flux: `https://flux.kubegit.com/oauth2/callback`
- Kagent: `https://kagent.kubegit.com/oauth2/callback`
- Grafana: `https://grafana.kubegit.com/login/generic_oauth`
- Kiali: `https://kiali.kubegit.com` (no path)
