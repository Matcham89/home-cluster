# Contributing

Pre-merge checks for this repo. Flux reconciles `main` directly onto the cluster, so a bad
manifest is a cluster problem, not a red build — **these checks are the only gate that exists.**

> **CI does not run any of this.** `.github/workflows/` contains only `renovate.yaml` (dependency
> updates). Nothing validates Terraform or Kustomize builds on a PR. If you skip the steps below,
> nobody and nothing will catch the mistake before it reaches the cluster.

## Terraform (`terraform/authentik/`)

> **Note on terminology:** there is no Terragrunt in this repo — no `terragrunt.hcl`, no
> `root.hcl`, no stacks. `terraform/authentik/` is a single plain-Terraform root module
> (`required_version = ">= 1.5"`, see `providers.tf`). Run plain `terraform` commands, not
> `terragrunt`.

### Before opening a PR

```bash
# From the repo root — formatting, no providers or credentials needed
terraform fmt -recursive

# Or, to check without rewriting files (what you'd want in a review)
terraform fmt -check -recursive
```

```bash
# Validation must run from inside the root module
cd terraform/authentik
terraform init      # required before validate — see below
terraform validate
```

### What each command actually needs

| Command | Needs providers (`init`) | Needs kubeconfig | Needs `TF_VAR_authentik_token` | Talks to the cluster / Authentik |
|---|---|---|---|---|
| `terraform fmt` | no | no | no | no |
| `terraform validate` | **yes** | no | no | no |
| `terraform plan` | yes | **yes** | **yes** | **yes** |

- `terraform validate` fails with *"Missing required provider"* / *"module not installed"* unless
  `terraform init` has run first. `init` downloads `goauthentik/authentik` (`~> 2026.0`) and
  `hashicorp/kubernetes` (`~> 3.0`), so it needs network access — but it does **not** need cluster
  or Authentik credentials. `fmt` + `init` + `validate` is the full pre-PR loop and is safe to run
  from any machine.
- `terraform plan` is a different tier of requirement: the `kubernetes` provider reads
  `~/.kube/config` and the `data.kubernetes_secret_v1` lookups in `data.tf` hit a live cluster,
  while the `authentik` provider hits the live Authentik API and needs a superuser API token:

  ```bash
  export TF_VAR_authentik_token="<token>"
  export TF_VAR_kube_context="my-cluster-context"   # optional; defaults to current context
  terraform plan
  ```

  Getting that token (including a headless `ak shell` bootstrap), plus the fresh-cluster ordering
  and troubleshooting for `403 Forbidden` / `flow not found`, is documented in
  [terraform/authentik/README.md](terraform/authentik/README.md). If you can't reach the cluster,
  say so in the PR and stop at `validate` — don't guess at the plan output.

State is local (`terraform.tfstate`, gitignored), so there is no shared lock to worry about and
no state to corrupt for anyone else.

## Flux manifests (`flux/`)

### The three-layer indirection

This is the thing that makes "just render it" insufficient. A change reaches the cluster through
three layers:

```
flux/clusters/dev/cluster-apps.yaml   ← root Flux Kustomization, path: ./flux/apps/dev
flux/apps/dev/<ns>/<component>/ks.yaml ← Flux Kustomization objects, each path: ./flux/apps/base/...
flux/apps/base/<ns>/<app>/             ← the actual Kubernetes manifests
```

A given render command only exercises **one** layer. Pick the one matching what you edited:

| You changed | Validate with |
|---|---|
| Manifests under `flux/apps/base/<ns>/<app>/` | `kubectl kustomize flux/apps/base/<ns>/<app>` |
| A `ks.yaml` or `kustomization.yaml` under `flux/apps/dev/` | `flux build kustomization cluster-apps --path ./flux/apps/dev --dry-run` |
| Added a new app (both layers) | **both** of the above |

```bash
# Render the root Kustomization offline — no cluster connection required
flux build kustomization cluster-apps --path ./flux/apps/dev --dry-run

# Preview one app's rendered manifests
kubectl kustomize flux/apps/base/authentik/operator
```

**`flux build ... --path ./flux/apps/dev` does not recurse into `apps/base`.** It renders the
Flux `Kustomization` *resources* declared in `apps/dev` — it proves your `ks.yaml` is well-formed
and that the overlay aggregates, but it never reads the manifests at the `path:` those resources
point to. A typo'd `path:` renders perfectly here and fails on the cluster. Check the path exists:

```bash
# Every path: referenced by a ks.yaml should be a real directory
grep -rh 'path: \./flux/apps/base' flux/apps/dev | awk '{print $2}' | sort -u | while read -r p; do
  [ -d "${p#./}" ] || echo "MISSING: $p"
done
```

### Gotchas that render clean and still do nothing

- **A directory not listed in `flux/apps/dev/kustomization.yaml` is invisible.** New namespace
  directories must be added to its `resources:` list, otherwise the app silently never deploys —
  `flux build` succeeds and simply omits it. Some entries are deliberately commented out
  (`kagent`, `substrate`); don't uncomment them as drive-by cleanup.
- **`dependsOn` ordering isn't checked by any render.** Secrets must reconcile before the app that
  consumes them — see the ordering table in [flux/CLAUDE.md](flux/CLAUDE.md).
- **NetworkPolicies in this repo are inert.** The CNI is Flannel, which has no policy engine, so a
  `default-deny-all` blocks nothing today. Don't treat one as a security control in review.

### After merging

```bash
flux get kustomizations -A                              # watch it land
flux reconcile kustomization cluster-apps --with-source # force a sync instead of waiting
kubectl describe kustomization <name> -n flux-system    # why isn't it reconciling
flux logs --follow --level=error
```

## Other checks

There is no test runner, linter, or build system in this repo — no `Makefile`, no `package.json`,
no pre-commit config. The Terraform and Flux commands above are the complete verification surface.
`scripts/` holds one-off operational scripts, not checks.

## Where else to look

- [flux/CLAUDE.md](flux/CLAUDE.md) — architecture reference: app directory pattern, `ks.yaml`
  template, namespace `infra/` components, ingress/oauth2-proxy pattern, secret management.
- [bootstrap/README.md](bootstrap/README.md) — installing Flux on a fresh cluster, disaster recovery.
- [terraform/authentik/README.md](terraform/authentik/README.md) — Authentik API tokens, first
  apply, recovery after a database loss.
- [docs/](docs/) — dated design write-ups and investigations (point-in-time, not maintained as
  current-state documentation).
