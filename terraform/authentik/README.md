# Authentik Terraform

Manages Authentik configuration as code: OAuth2 providers, applications, and groups.

Running `terraform apply` fully restores Authentik config after a database loss — no manual UI work.

## What this manages

| Resource | Type | Notes |
|---|---|---|
| `flux-kubegit-com` | OAuth2 Provider + Application | Flux Web UI |
| `kagent-kubegit-com` | OAuth2 Provider + Application | Kagent (via oauth2-proxy) |
| `agentdesktop-kubegit-com` | OAuth2 Provider + Application | AgentDesktop admin web UI (via oauth2-proxy) |
| `agentdesktop` | OAuth2 Provider + Application | AgentDesktop CLI/daemon device enrollment — public/native client, redirect fixed to `http://127.0.0.1:51327/callback`; separate from the web UI provider above and can't be merged with it |
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

Note that only `terraform plan`/`terraform apply` need the cluster, the secrets, and the API token.
The pre-PR checks in "Local checks before opening a PR" need none of them — see that section.

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

## Local checks before opening a PR

Run these two checks on any PR that touches `terraform/`. Unlike `terraform plan`/`terraform apply`,
**neither needs cluster access, a kubeconfig, or `TF_VAR_authentik_token`** — you can run both on a
laptop that has never talked to the cluster. Nothing in the "Prerequisites" section above applies
here except having the `terraform` CLI itself.

```bash
cd terraform/authentik

# 1. Formatting — no init required
terraform fmt -recursive -check

# 2. Install the pinned providers, then validate
terraform init -backend=false
terraform validate
```

Both should exit `0`.

Why no credentials are needed:

- `terraform fmt` is a pure source-text check. It never loads providers or evaluates configuration,
  so it works straight from a fresh clone.
- `terraform validate` checks syntax, references, and type correctness against the provider schemas.
  It needs the providers *installed* — hence the `terraform init` first, which downloads
  `goauthentik/authentik ~> 2026.0` and `hashicorp/kubernetes ~> 3.0` from the registry (network
  access to the registry only, not to the cluster). It does **not** evaluate `provider` blocks, so
  the `config_path = "~/.kube/config"` in `providers.tf` is never dialled, and it does **not**
  require values for input variables, so the no-default `authentik_token` can stay unset.
- `-backend=false` on `init` skips backend initialisation. It's not strictly required today (state
  is local — see "State"), but it keeps the check working unchanged if a remote backend is ever
  configured.

Useful variants:

- `terraform fmt -recursive` (without `-check`) rewrites files in place to fix formatting.
- Run `terraform fmt -recursive -check` from the repo root to cover every `.tf` file in the tree at
  once; `terraform validate` is per-module, so it must be run from `terraform/authentik`.

Two things to be aware of:

- **No CI enforces this.** `.github/workflows/` currently contains only `renovate.yaml` — there is
  no fmt/validate job, so these checks are contributor-run only. An unformatted or invalid `.tf`
  file will merge without complaint if you skip them.
- **There is no terragrunt in this repo.** The IaC here is plain Terraform, and `terraform/` holds
  the single `authentik/` module. If you see a reference to `terragrunt run-all` or similar for this
  repo, it's a naming error — the commands above are the real workflow.

A passing `validate` does not mean a clean `plan`. Errors that depend on live API state — missing
flow slugs, a missing certificate, an absent Kubernetes secret, a non-superuser token — only surface
during `plan`/`apply`, which do need the full Prerequisites. See "Troubleshooting" for those.

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
