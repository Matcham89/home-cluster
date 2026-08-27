# Authentik Terraform

Manages Authentik configuration as code: OAuth2 providers, applications, and groups.

Running `terraform apply` fully restores Authentik config after a database loss — no manual UI work.

## What this manages

| Resource | Type | Notes |
|---|---|---|
| `flux-kubegit-com` | OAuth2 Provider + Application | Flux Web UI |
| `kagent-kubegit-com` | OAuth2 Provider + Application | Kagent (via oauth2-proxy) |
| `grafana-kubegit-com` | OAuth2 Provider + Application | Grafana generic OAuth |
| `flux-admins` | Group | Bound to `flux-web-admin` ClusterRole |
| `Grafana Admins` | Group | Maps to Grafana Admin role |
| `Grafana Editors` | Group | Maps to Grafana Editor role |
| `matcham89` | User | Personal admin account. Member of `authentik Admins` (superuser, referenced via data lookup, not owned by this Terraform) plus all 3 groups above. No email/password is set here — see "Post-apply: set up the matcham89 login" below. |

Client credentials are read directly from existing cluster secrets — no secrets are stored in this repo or in Terraform state in plaintext.

## Prerequisites

- `terraform` >= 1.5
- `kubectl` configured and pointing at the cluster (to read client secrets)
- Authentik itself already deployed and `Running` (`kubectl -n authentik get pods`) — this Terraform
  configures Authentik, it doesn't install it
- The Kubernetes secrets in the "What this manages" client-credentials column must already exist
  (created by the app's own `ExternalSecret`/Flux resources) — the `data.kubernetes_secret_v1.*`
  lookups fail otherwise
- An Authentik API token (see below)

## Fresh-cluster bootstrap order

On a brand new cluster, Authentik starts with an empty database — there is no admin login yet, and
none of the applications below exist. Order matters:

1. Wait for `authentik-operator-server`/`authentik-operator-worker` pods to be `Running` in the
   `authentik` namespace.
2. Get an admin session via the recovery-key flow (see "Recovering after a database loss" — same
   steps apply to a fresh install, not just a restored one).
3. Get an API token — either through the UI, or headlessly via `ak shell` (see below).
4. `terraform init && terraform plan && terraform apply` (see "First Apply").
5. Post-apply: set a real password for `matcham89` (see below) — don't keep relying on the akadmin
   recovery link.

## Getting an Authentik API Token

1. Log in to Authentik at `https://authentik.kubegit.com`
2. Go to **Admin Interface** → **Directory** → **Tokens and App Passwords**
3. Click **Create** → Token type: **API Token**
4. Copy the token value

Note: a normal user's token is not enough — the `goauthentik/authentik` provider needs admin-level
read access (e.g. `GET /api/v3/flows/instances/` returns `403 Forbidden` otherwise). In Authentik,
`is_superuser` is derived from group membership, not a flag on the user, so the token's user must
belong to the `authentik Admins` group (or another superuser group).

### Headless alternative: bootstrap the service account via `ak shell`

If you'd rather not click through the UI (or are scripting a fresh-cluster bootstrap), this
creates/repairs a dedicated `terraform_kubegit_service_account` service account, ensures it's in
`authentik Admins`, and ensures its API token exists — idempotent, safe to re-run (it reuses the
existing token key rather than rotating it):

```bash
kubectl exec -n authentik deploy/authentik-operator-server -- ak shell -c "
from authentik.core.models import User, Token, TokenIntents, Group, UserTypes

group = Group.objects.get(name='authentik Admins')

user, created = User.objects.get_or_create(
    username='terraform_kubegit_service_account',
    defaults={'name': 'terraform_kubegit_service_account', 'type': UserTypes.SERVICE_ACCOUNT},
)
group.users.add(user)

token, _ = Token.objects.update_or_create(
    identifier='terraform_kubegit_token',
    defaults={'user': user, 'intent': TokenIntents.INTENT_API, 'expiring': False},
)

print('is_superuser:', User.objects.get(pk=user.pk).is_superuser)
print('TOKEN:', token.key)
"
```

Copy the printed `TOKEN:` value into `TF_VAR_authentik_token` below. This requires a running
`authentik-operator-server` pod — if Authentik itself has no admin user yet (fresh database), do
the recovery-key dance in "Recovering after a database loss" first.

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

## Post-apply: set up the matcham89 login

`terraform apply` creates the `matcham89` user with no email and no password (both deliberately
kept out of this repo/state). Two manual steps after every apply that (re)creates this user (first
apply on a fresh cluster, or any recovery-after-database-loss):

1. Set a password via the recovery-key flow:

```bash
kubectl exec -n authentik deploy/authentik-operator-server -- ak create_recovery_key 86400 matcham89
```

   Open the printed URL and set a password.

2. (Optional) Set an email address via **Admin Interface → Directory → Users → matcham89 → Edit**
   if an app needs it for OIDC email-claim-based matching (e.g. Grafana user lookup).

## Recovering after a database loss

This is the primary reason this Terraform exists. After Authentik is back up with a fresh database:

1. Generate a recovery token for `akadmin`:

```bash
kubectl exec -n authentik deploy/authentik-operator-server -- ak create_recovery_key 86400 akadmin
```

   Open the printed URL in your browser to log in as `akadmin`.

2. Create a new API token (see above), or use the headless `ak shell` alternative below.
3. Run:

```bash
export TF_VAR_authentik_token="<new-token>"
terraform apply
```

All applications, groups, and the `matcham89` user are recreated in well under a minute. No k8s
secrets need to change since the same client IDs and secrets are reused.

4. `matcham89` comes back from a database loss with no password (Terraform never stores one — see
   "Post-apply" below) — redo the recovery-key flow for `matcham89` to set one again.

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

**`403 Forbidden` on plan (`GET /api/v3/flows/instances/`)**
The token's user isn't a superuser. In Authentik, `is_superuser` is derived from group membership,
not a flag on the user — add the user to `authentik Admins` (see "Headless alternative" above,
which does this for the Terraform service account).

**Login redirects to `/oauth2/callback?error=invalid_request&error_description=The request is
otherwise malformed`, and the app shows its own 403 page ("Secured with OAuth2 Proxy" or similar)**
Check the Authentik server logs for `"Invalid grant_type for provider"` — every
`authentik_provider_oauth2` resource in this repo sets `grant_types` explicitly for exactly this
reason. The field is `optional, computed` in the provider schema, but if you ever remove it,
Authentik defaults the underlying `grant_types` to an **empty list** (not a sane default), so every
authorization request is rejected. If this happens on a provider not managed by this Terraform,
you can patch it directly:

```bash
kubectl exec -n authentik deploy/authentik-operator-server -- ak shell -c "
from authentik.providers.oauth2.models import OAuth2Provider, GrantType
p = OAuth2Provider.objects.get(name='<Provider Name>')
p.grant_types = [GrantType.AUTHORIZATION_CODE, GrantType.REFRESH_TOKEN]
p.save()
"
```

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
