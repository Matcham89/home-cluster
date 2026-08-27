# ate-system / substrate ClusterTrustBundle investigation — 2026-08-27

## Status: RESOLVED

All `ate-system` pods (`postgres-0`, `ate-controller`, `ate-api-server`, `atelet`,
`atenet-router`, `atenet-egress`) and the `substrate` HelmRelease are healthy
(`UpgradeSucceeded`, chart `0.0.21`). Three independent, stacked issues had to be fixed;
see "Root causes" below. Full bootstrap procedure now lives in
`docs/substrate-openclaw-open-items.md`'s sibling
[`docs/substrate-bootstrap-requirements.md`](./substrate-bootstrap-requirements.md) —
read that first on any future rebuild.

## Summary

On this cluster's upgrade to `kagent-dev/substrate` chart `v0.0.21`, several `ate-system`
pods (`postgres-0`, `ate-controller`, `ate-api-server`, `atelet`, `atenet-router`,
`atenet-egress`) got stuck failing to start, and the `substrate` HelmRelease was
terminally stalled. Three separate issues stacked on top of each other:

1. Talos didn't have the `ClusterTrustBundle`, `ClusterTrustBundleProjection`, and
   `PodCertificateRequest` Beta feature gates enabled (fixed same-day, see "Fix
   applied" below — this part was resolved before the remaining two were found).
2. **Missing bootstrap secrets/configmap** the chart's `README`/templates never
   create: `actor-id-jwt-pool`, `actor-id-ca-pool`, `actor-id-ca-certs`,
   `ate-api-authentication` (ate-system), and `service-dns-ca-pool` /
   `pod-identity-ca-pool` (podcertificate-controller-system). Without these,
   `podcertificate-controller` can't even start, so no `ClusterTrustBundle`s exist.
3. **Missing RBAC**: even with the ClusterTrustBundles present, every workload's
   `podCertificate`/`clusterTrustBundle` projection was silently reduced to
   `sources: [{}]`. Kubernetes requires the identity that submits the object
   containing the pod template — for a HelmRelease with no `serviceAccountName`
   override, that's **`system:serviceaccount:flux-system:helm-controller`**, and for
   directly-created Pods, **the pod's own `spec.serviceAccountName`** — to hold `use`
   on the exact signer name (`certificates.k8s.io` `signers`, resourceName
   `<signer>/identity`, apiGroup `certificates.k8s.io`). The chart ships `sign`/`attest`
   RBAC for the signer's own controller, but never grants `use` to anything. See
   "Root cause 2: missing `use` RBAC" below for how this was isolated.
4. A follow-on version-skew bug: `flux/apps/base/kagent/operator/helmrelease.yaml`
   pinned `substrateWorkerPool.ateomImage` to `ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.6`
   (from an earlier, unrelated OpenClaw gVisor investigation —
   `docs/substrate-openclaw-talos.md`). Once `ate-controller` was upgraded to `0.0.21`,
   it started passing worker actors a new `--atunnel-listen-address` flag that `v0.0.6`'s
   `ateom-gvisor` binary didn't recognize, crash-looping every `kagent-default` actor pod.
   Fixed by bumping the pin to `v0.0.21` to match the substrate chart version (comment in
   that file already said "tag must match the substrate chart version" — it just hadn't
   been bumped alongside the chart).

**Also of note (same-day, earlier):** applying the feature-gate fix caused a real, if
brief, cluster-wide outage (all 5 nodes `NotReady`) due to an incomplete kubelet
feature-gate value. Fully recovered; details in "What went wrong" below.

## What was broken

Pods mounting a `projected` volume with a `clusterTrustBundle` or `podCertificate`
source (`servicedns.podcert.ate.dev/identity` and `podidentity.podcert.ate.dev/identity`
signers) got an effectively empty projection (`sources: - {}`), so the expected files
never appeared:

- `postgres-0`: `could not load server certificate file "/run/servicedns.podcert.ate.dev/credential-bundle.pem"`
- `ate-controller`: `ateapiauth: reading CA file: open /run/servicedns-ca/trust-bundle.pem: no such file or directory`
- `atelet` (DaemonSet): `Failed to watch ... *v1beta1.ClusterTrustBundle: the server could not find the requested resource` (before the API was enabled), later `Failed to build server TLS config: read CA bundle ... no such file or directory` (after)

The chart's own `values.yaml` states the feature-gate requirement directly:

> "The chart requires ClusterTrustBundle, ClusterTrustBundleProjection, PodCertificateRequest, and
> the certificates.k8s.io/v1beta1 API."

None of these were enabled on this cluster's kube-apiserver or kubelet at first boot.

## Fix applied (feature gates)

**kube-apiserver** (`cluster.apiServer.extraArgs`, control planes only):
```yaml
feature-gates: ClusterTrustBundle=true,ClusterTrustBundleProjection=true,PodCertificateRequest=true
runtime-config: certificates.k8s.io/v1beta1=true
```

**kubelet** (`machine.kubelet.extraArgs`, **all 5 nodes** — workloads using these volume
types can land anywhere):
```yaml
feature-gates: ClusterTrustBundle=true,ClusterTrustBundleProjection=true,PodCertificateRequest=true
```

All three feature gates are confirmed **BETA, default=false** in Kubernetes 1.36.3 (verified via
`kube-apiserver --help` against a throwaway pod running the exact `registry.k8s.io/kube-apiserver:v1.36.3`
image — safe way to check valid gate names/defaults without touching the live apiserver).

Verified live and applied:
- `kubectl get nodes` — all 5 `Ready`
- `kubectl -n kube-system get pod -l component=kube-apiserver` — all 3 report the full feature-gate
  string in their command args
- `talosctl -n <ip> service kubelet` — `HEALTH: OK` on every node

### Persisted to `/Users/macbook/talos-config`

- `controlplane.yaml`: `apiServer.extraArgs` (new) and `kubelet.extraArgs` (new), both with the full
  gate list and a comment explaining why.
- `worker.yaml`: `kubelet.extraArgs` (new), same gate list.
- `rendered/control-0{1,2,3}.yaml` and `rendered/worker-0{1,2}.yaml`: re-rendered from the updated
  base configs via `talosctl machineconfig patch ... -o rendered/<node>.yaml` and re-validated
  (`talosctl validate --mode metal --strict`) — all 5 pass.
- No per-node `*-patch-N.yaml` files needed changes (none of them touch `apiServer.extraArgs` beyond
  `certSANs`, or `kubelet` at all — confirmed no merge conflicts before editing).

This means a **future full re-bootstrap from `talos-config` will already have these gates enabled**
— this exact issue should not recur on a from-scratch rebuild. The secrets and RBAC below, however,
are **not** part of `talos-config` and **will** need to be redone on a from-scratch rebuild — see
`docs/substrate-bootstrap-requirements.md`.

## What went wrong (for the record)

The apiserver-only patch was applied first and worked cleanly. When adding the other two gates, I
patched kubelet's `extraArgs.feature-gates` to `ClusterTrustBundleProjection=true,PodCertificateRequest=true`
— **omitting** `ClusterTrustBundle=true`, which the other two depend on. Kubelet refused to start on
every node with:

```
failed to set feature gates from initial flags-based config: ClusterTrustBundleProjection is enabled, but depends on features that are disabled: [ClusterTrustBundle]
```

Since this happened simultaneously on all 5 nodes (patched in one `talosctl patch mc -n <all 5 IPs>`
call), every kubelet crash-looped at once and every node went `NotReady`. Recovered by re-patching
each node individually with the complete 3-gate list (`ClusterTrustBundle=true` included) — kubelet
came back healthy within seconds of the corrected config landing, no reboot needed on any node.

Lesson for next time: when a Kubernetes Beta feature has documented dependencies between gates
(`X depends on Y`), set the full dependency chain in one patch, not incrementally.

## Root cause 2: missing bootstrap secrets

Even with the feature gates enabled, `podcertificate-controller` (namespace
`podcertificate-controller-system`) never started:

```
MountVolume.SetUp failed for volume "ca-state" : [secret "service-dns-ca-pool" not found, secret "pod-identity-ca-pool" not found]
```

The chart's `templates/pod-certificate-controller.yaml` mounts these two secrets (plus
`actor-id-jwt-pool` / `actor-id-ca-pool` / `actor-id-ca-certs` / the `ate-api-authentication`
ConfigMap for `ate-api-server`) but **never creates them** — they're an undocumented
prerequisite. The upstream project's own `hack/install-ate.sh` creates them via
`go run ./cmd/kubectl-ate admin make-ca-pool` / `make-jwt-pool` (a CLI that generates a
local CA/JWT authority and uploads it as a Secret) before deploying the chart. Full
commands captured in `docs/substrate-bootstrap-requirements.md`.

## Root cause 3: missing `use` RBAC on the podcert signers (the real "remaining issue")

An earlier pass at this investigation (same day) suspected an RBAC gap here but didn't
pin it down — recorded then as "Remaining issue — NOT fixed". Fully isolated this pass:

Kubernetes drops the `signerName` (and the whole source) from a
`podCertificate`/`clusterTrustBundle` projection at admission time unless the identity
performing the write is authorized `use` on that exact signer name
(`certificates.k8s.io` `signers`, verb `use`, resourceName e.g.
`servicedns.podcert.ate.dev/identity`). This chart ships RBAC for the *signer's own*
controller to `sign`/`attest` (`podcert-ate-dev-signer` ClusterRole), but nothing grants
any workload `use`.

**The subtlety:** it is not the pod's own `serviceAccountName`, nor the built-in
`kube-system:{replicaset,statefulset,daemon-set}-controller` service accounts, that need
the grant for objects applied via a Flux `HelmRelease` with no
`spec.serviceAccountName` override — it's **`system:serviceaccount:flux-system:helm-controller`**,
because that's the identity that actually calls the Kubernetes API to server-side-apply
the StatefulSet/Deployment/DaemonSet object containing the pod template. (Confirmed by:
admin-created Pods and impersonated-as-`kube-system:*`-controller Pods both preserved
the field regardless of RBAC; only re-running the *actual* Helm upgrade, after granting
`use` to the actual applying identities, fixed the **stored StatefulSet/Deployment
template itself** — the live objects had the field permanently stripped from a prior
failed/partial apply and needed a fresh `helm upgrade` pass to pick up the fix, not just
a pod restart.)

Fix: `flux/apps/base/substrate/substrate-operator/rbac-podcert-signer-use.yaml` — a
ClusterRole granting `use` on both signer names, bound to the `ate-system` workload
ServiceAccounts (`default`, `ate-api-server`, `ate-controller`, `atenet-egress`,
`atenet-router`, `atelet`). `helm-controller` itself already has `cluster-admin` via
`cluster-reconciler-flux-system`, so no separate grant was needed for it — the missing
piece was purely for the pod-level SAs.

After granting this RBAC, the **already-broken** StatefulSet/Deployment/DaemonSet
objects still needed a fresh Helm upgrade to re-stamp their templates
(`flux suspend helmrelease substrate -n ate-system && flux resume helmrelease substrate -n ate-system`
— toggling suspend is what actually resets Flux's exceeded-retries "Stalled" state and
forces a new `helm upgrade` attempt; a plain `flux resume` on an already-unsuspended
release is a no-op). Once that upgrade succeeded, `postgres-0`, `ate-api-server`, and
the `atenet-router`/`atenet-egress`/`atelet` DaemonSet pods all needed a manual
`kubectl delete pod` (StatefulSets/DaemonSets don't proactively replace already-running
pods on template change the way Deployments roll a new ReplicaSet do) to pick up the
corrected volume projections.

## Root cause 4: `ateomImage` version pinned to a stale substrate release

Separately, `kagent-default` worker actor pods (namespace `kagent`) started
crash-looping with:

```
unknown flag: --atunnel-listen-address
```

`flux/apps/base/kagent/operator/helmrelease.yaml` pins
`substrateWorkerPool.ateomImage` to `ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.6`
— left over from the unrelated OpenClaw gVisor checkpoint/restore investigation
(`docs/substrate-openclaw-talos.md`, resolved 2026-06-16). The comment in that file
already said this image "must match the substrate chart version," but nobody bumped it
when substrate went to `0.0.21` — `ate-controller@0.0.21` passes worker pods a flag
`ateom-gvisor@v0.0.6` doesn't understand. Fixed by bumping the pin to
`ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.21` (confirmed present via
`docker manifest inspect` before changing it).

**Follow-up worth doing:** consider wiring `ateomImage`'s tag to the same Renovate
`datasource=github-releases depName=kagent-dev/substrate` annotation used for the
substrate chart's own `OCIRepository` tag, so the two can't drift apart silently again.

## Confirmation

- `kubectl get pods -A` — no non-`Running`/`Completed` pods cluster-wide.
- `kubectl -n ate-system get helmrelease substrate` — `Ready=True`,
  `UpgradeSucceeded for release ate-system/substrate.v4 with chart substrate@0.0.21`.
- `kubectl get podcertificaterequests -A` — all `Issued`.
- `kubectl get clustertrustbundles` — both `servicedns.podcert.ate.dev:identity:primary-bundle`
  and `podidentity.podcert.ate.dev:identity:primary-bundle` present.
