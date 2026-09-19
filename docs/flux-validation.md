# Validating Flux changes before you merge

**Who this is for:** anyone opening a pull request that touches anything under `flux/`.

**Why it matters:** there is no CI gate on this repo — `.github/workflows/` only runs
Renovate, so nothing validates your manifests for you. The `FluxInstance` in
`flux/clusters/dev/flux-instance.yaml` syncs `refs/heads/main` at `interval: 1m`, which
means a merged change reaches the live cluster within about a minute. A manifest that
fails to render is caught by the cluster, not by review. Render it locally first.

This document is the contributor-facing checklist. [`flux/CLAUDE.md`](../flux/CLAUDE.md)
is the deeper reference for the repository's architecture, naming conventions, and
per-application patterns — read it when you need the "why" behind the layout; read this
when you need the "did I break it" commands.

---

## Prerequisites

| Tool | Needed for |
|---|---|
| [`flux`](https://fluxcd.io/flux/installation/) CLI | rendering Flux Kustomizations (`flux build`) |
| `kubectl` (v1.14+, includes Kustomize) | rendering plain Kustomize directories (`kubectl kustomize`) |
| cluster access (kubeconfig) | **post-merge verification only** — not needed for the pre-merge render |

The pre-merge render below uses `--dry-run`, which builds entirely from your local
working tree. You do **not** need cluster credentials to validate a change, so an
outside contributor can run the full pre-merge checklist.

---

## Which path do I render?

This repo has three layers, and each one is validated with a different command. Pick
based on where your change landed:

```
flux/clusters/dev/      ← Flux entrypoint (FluxInstance + root Kustomization)
flux/apps/dev/          ← Flux Kustomization resources (ks.yaml) pointing at base paths
flux/apps/base/         ← the actual Kubernetes manifests (HelmReleases, CRDs, policies)
flux/infra/             ← reusable Kustomize Components for namespace templates
```

| You changed | Render with |
|---|---|
| Anything under `flux/apps/dev/` (a `ks.yaml`, a namespace `kustomization.yaml`, an `infra/` component reference) | `flux build kustomization cluster-apps --path ./flux/apps/dev --dry-run` |
| Anything under `flux/apps/base/<namespace>/<app>/` (HelmRelease, Deployment, ExternalSecret, policies) | `kubectl kustomize flux/apps/base/<namespace>/<app>` |
| A component under `flux/infra/` | both of the above — the component is consumed by every `flux/apps/dev/<namespace>/kustomization.yaml` that references it |
| Anything under `flux/clusters/dev/` | `kubectl kustomize flux/clusters/dev` (and re-read the note on `flux-instance.yaml` below) |

### 1. Render the `apps/dev` layer

```bash
flux build kustomization cluster-apps --path ./flux/apps/dev --dry-run
```

This is the single most valuable check: it builds exactly what the root `cluster-apps`
Kustomization (`flux/clusters/dev/cluster-apps.yaml`) sources, so it catches a
malformed `ks.yaml`, a namespace `kustomization.yaml` that forgot to list your new
`ks.yaml` under `resources:`, and a broken `components:` path.

A clean run prints the rendered YAML. Any error means the change would fail to
reconcile — fix it before merging.

### 2. Render the `apps/base` layer for the app you touched

```bash
kubectl kustomize flux/apps/base/authentik/secrets     # example
kubectl kustomize flux/apps/base/<namespace>/<app>
```

`flux build` on `apps/dev` renders the *Flux Kustomization objects*, not the manifests
they point at — the controller fetches those separately at reconcile time. So a typo
inside `flux/apps/base/` will **not** be caught by step 1. Render each base directory
you edited.

### 3. Sanity-check the wiring

Cheap greps that catch the most common review findings:

- **New directory is actually referenced.** If you added `flux/apps/base/<ns>/<app>/`,
  confirm a matching `ks.yaml` exists in `flux/apps/dev/<ns>/` and that the namespace's
  `kustomization.yaml` lists it under `resources:`. An unreferenced directory renders
  fine and silently deploys nothing.
- **`path:` in each `ks.yaml` resolves.** It is repo-root-relative and starts with
  `./flux/apps/base/...`. A path that does not exist produces a Kustomization stuck in
  a retry loop rather than a render error.
- **`dependsOn` names and namespaces are correct.** `dependsOn` refers to *other Flux
  Kustomization objects*, by `metadata.name`, and needs an explicit `namespace:` when
  the dependency lives outside `flux-system`. Example from
  `flux/apps/dev/authentik/secrets/ks.yaml`:

  ```yaml
  dependsOn:
    - name: external-secrets-store
      namespace: kube-ops
  ```

  A `dependsOn` pointing at a name that does not exist does not fail validation — the
  Kustomization simply never becomes ready, waiting on a dependency that will never
  arrive. Grep for the name you referenced to confirm it exists.
- **Install order.** New apps generally need `dependsOn` on some subset of:
  `cert-manager` (TLS), `cnpg-system` (PostgreSQL), `ingress-gateway` (HTTPRoutes),
  `kube-prometheus-stack` (ServiceMonitors), and `1password` → `external-secrets`
  (anything with an ExternalSecret). See the dependency list at the end of
  `flux/CLAUDE.md`.

---

## Two traps that render cleanly and still surprise you

These both pass every command above. Neither is a bug in your change — they are
properties of this cluster that are easy to get wrong.

### NetworkPolicies are inert — the CNI is Flannel

Flannel has no NetworkPolicy engine. Every `NetworkPolicy` object in this repo, in
every namespace, does nothing: `kubectl get networkpolicy` lists them and Flux reports
them healthy, but nothing evaluates them and traffic flows regardless of what they say.

They are kept as documentation of intended traffic shape, and would become real the
moment Flannel is swapped for a policy-capable CNI (Calico, Cilium, …).

**What this means for you:** do not treat an existing `default-deny-all` as protection
you are working within, and do not conclude your app works because a policy "allowed"
it. Still write the policy — match the existing pattern in
`flux/apps/base/network-policies/` — but validate connectivity by actually exercising
the path.

### ExternalSecrets depend on 1Password + ESO, and they are not instant

Secrets are delivered by External Secrets Operator pulling from 1Password (the
1Password Connect operator runs in the `1password` namespace). An `ExternalSecret`
manifest renders fine whether or not the underlying 1Password item exists, whether or
not the field names match, and whether or not ESO is ready.

When adding an app that consumes secrets:

- Put the `ExternalSecret` in `flux/apps/base/<namespace>/<app>/secrets/`.
- Give the app's `secrets/ks.yaml` a `dependsOn` on the 1Password/ESO Kustomization
  **and** `wait: true`, so downstream workloads do not start before the secret exists.
- Confirm the referenced 1Password item and field names exist before merging — a
  mismatch shows up as a `SecretSyncedError` on the `ExternalSecret` and a pod stuck in
  `CreateContainerConfigError`, not as a Flux failure.

---

## After you merge

The sync interval is 1 minute, so within roughly a minute of the merge:

```bash
# Overall state — look for anything not Ready
flux get kustomizations -A
flux get helmreleases -A

# Don't want to wait for the interval? Force it
flux reconcile kustomization cluster-apps --with-source
flux reconcile helmrelease <name> -n <namespace>

# Something is not Ready — get the actual reason
kubectl describe kustomization <name> -n flux-system
flux logs --follow --level=error
```

`kubectl describe kustomization` is the one that tells you *why*: a build error, a
missing path, or a `dependsOn` that never became ready all surface in its status
conditions and events.

If your change broke the cluster, revert the commit. Flux will pick the revert up on
the same 1-minute interval — there is no separate rollback mechanism.

---

## Further reading

- [`flux/CLAUDE.md`](../flux/CLAUDE.md) — repository architecture, the three-layer
  model, `ks.yaml` template, namespace infra components, ingress and oauth2-proxy
  patterns, secret management, monitoring, and the full `dependsOn` install order.
- [`bootstrap/README.md`](../bootstrap/README.md) — installing Flux from scratch.
- [`docs/substrate-bootstrap-requirements.md`](substrate-bootstrap-requirements.md) —
  the substrate/kagent stack has bootstrap requirements that are deliberately *not* in
  git; read this before touching it.
- [Flux documentation](https://fluxcd.io/flux/) — upstream reference for `flux build`,
  `flux reconcile`, and Kustomization semantics.
