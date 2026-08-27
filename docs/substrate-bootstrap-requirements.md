# Substrate + kagent enablement requirements — confirmed, not assumed

**Purpose of this document:** every prerequisite this cluster needs to run
`kagent-dev/substrate` (backing kagent's WorkerPools) — what it is, why it's needed
(with evidence, not inherited assumption), the exact commands used, and where the
information came from. Each item is tagged with a verification status. This
supersedes the "what to do" content of earlier docs; see
`docs/2026-08-27-ate-system-clustertrustbundle-investigation.md` for the incident
narrative this was derived from.

**Status legend**
- ✅ **CONFIRMED REQUIRED** — empirically shown to break something specific without it
- ⚠️ **CONFIRMED REQUIRED, CURRENTLY MISSING** — shown required, but not actually in place on this cluster right now
- ❌ **CONFIRMED DEAD / NOT NEEDED** — present in config from a past investigation, verified to do nothing against the versions actually deployed
- ℹ️ **CONFIRMED NEEDED, NOT YET RE-TESTED END-TO-END** — plausible/documented requirement, not independently re-verified this pass

---

## 1. Kubernetes feature gates ✅ CONFIRMED REQUIRED

**What:** `ClusterTrustBundle`, `ClusterTrustBundleProjection`, `PodCertificateRequest`
(kube-apiserver + kubelet, all nodes) and `runtime-config: certificates.k8s.io/v1beta1=true`
(kube-apiserver only).

**Why:** the substrate chart's own `README.md`/`values.yaml` state this outright:
> "The chart requires ClusterTrustBundle, ClusterTrustBundleProjection, PodCertificateRequest, and the certificates.k8s.io/v1beta1 API."

Empirically confirmed: `postgres-0`/`ate-controller`/`atelet` all failed with
`the server could not find the requested resource` for `*v1beta1.ClusterTrustBundle`
before this was enabled.

**How (already applied and persisted):**
```yaml
# controlplane.yaml — cluster.apiServer.extraArgs
feature-gates: ClusterTrustBundle=true,ClusterTrustBundleProjection=true,PodCertificateRequest=true
runtime-config: certificates.k8s.io/v1beta1=true

# controlplane.yaml + worker.yaml — machine.kubelet.extraArgs (ALL 5 nodes)
feature-gates: ClusterTrustBundle=true,ClusterTrustBundleProjection=true,PodCertificateRequest=true
```
Applied live via `talosctl patch mc -n <ip> ...`, then persisted into
`/Users/macbook/talos-config/{controlplane,worker}.yaml` and re-rendered into
`rendered/*.yaml` (`talosctl machineconfig patch ... -o rendered/<node>.yaml`,
re-validated with `talosctl validate --mode metal --strict`).

**Gotcha (caused a full cluster-wide outage once, since fixed):**
`ClusterTrustBundleProjection` and `PodCertificateRequest` both depend on
`ClusterTrustBundle`. Setting only the two dependents crash-loops kubelet on
**every** node it's applied to simultaneously (`failed to set feature gates ...
depends on features that are disabled`). Always patch the full 3-gate list in one
shot.

**Where this lives:** `/Users/macbook/talos-config/controlplane.yaml` +
`worker.yaml` (`extraArgs` blocks with an explanatory comment) — persisted, survives
a rebuild from that repo.

---

## 2. Bootstrap secrets + ConfigMap ✅ CONFIRMED REQUIRED (live-cluster-only, not in git)

**What:**
| Name | Kind | Namespace | Consumed by |
|---|---|---|---|
| `actor-id-jwt-pool` | Secret | `ate-system` | `ate-api-server` (`--actor-id-jwt-pool`) |
| `actor-id-ca-pool` | Secret | `ate-system` | `ate-api-server` (`--actor-id-ca-pool`) |
| `actor-id-ca-certs` | Secret | `ate-system` | `atenet-egress` (`--actor-identity-ca-file`) — derived from `actor-id-ca-pool`'s root |
| `ate-api-authentication` | ConfigMap | `ate-system` | `ate-api-server` (`--authentication-config`) |
| `service-dns-ca-pool` | Secret | `podcertificate-controller-system` | `podcertificate-controller` (`--service-dns-ca-pool`) |
| `pod-identity-ca-pool` | Secret | `podcertificate-controller-system` | `podcertificate-controller` (`--pod-identity-ca-pool`) |

**Why:** the chart's `templates/*.yaml` mount all six by name but no template
*creates* them — verified by grepping every template in
`oci://ghcr.io/kagent-dev/substrate/helm/substrate:0.0.21` for `kind: Secret` /
`kind: ConfigMap` (only 4 unrelated ConfigMaps exist: `ate-api-server-envvars`,
and one each for `atenet-egress`/`atenet-router`/`postgres`). Confirmed empirically:
every consumer above hit `FailedMount ... secret "X" not found` /
`configmap "ate-api-authentication" not found` on first install. The chart's own
`README.md` doesn't mention this gap; it was reverse-engineered from
`kagent-dev/substrate`'s own `hack/install-ate.sh`, which creates exactly these six
before `helm upgrade` in its `deploy_ate_system` function.

**How (commands run, reusable verbatim on a rebuild):**
```bash
git clone https://github.com/kagent-dev/substrate.git /tmp/substrate-src
cd /tmp/substrate-src && go build -o /tmp/kubectl-ate ./cmd/kubectl-ate

/tmp/kubectl-ate admin make-jwt-pool --key-id=1 --name=actor-id-jwt-pool --secret-namespace=ate-system
/tmp/kubectl-ate admin make-ca-pool  --ca-id=1  --name=actor-id-ca-pool  --secret-namespace=ate-system

kubectl create namespace podcertificate-controller-system --dry-run=client -o yaml | kubectl apply -f -
/tmp/kubectl-ate admin make-ca-pool --ca-id=1 --name=service-dns-ca-pool  --secret-namespace=podcertificate-controller-system
/tmp/kubectl-ate admin make-ca-pool --ca-id=1 --name=pod-identity-ca-pool --secret-namespace=podcertificate-controller-system

actorid_root=$(
  kubectl get secret -n ate-system actor-id-ca-pool -o jsonpath='{.data.pool}' | base64 --decode \
    | grep -o '"RootCertificateDER":"[^"]*' | sed 's/"RootCertificateDER":"//' \
    | base64 --decode | openssl x509 -inform der -outform pem
)
kubectl create secret generic actor-id-ca-certs --from-literal=ca.crt="${actorid_root}" \
  -n ate-system --dry-run=client -o yaml | kubectl apply -f -

jwt_issuer=$(kubectl get --raw /.well-known/openid-configuration | grep -o '"issuer":"[^"]*' | sed 's/"issuer":"//')
kubectl create configmap -n ate-system ate-api-authentication \
  --from-literal=authentication.yaml="$(printf 'actorIdentityJWTProvider: kubernetes\njwtProviders:\n- name: kubernetes\n  issuer: %s\n  audiences: [api.ate-system.svc]\n' "${jwt_issuer}")" \
  --dry-run=client -o yaml | kubectl apply -f -
```
Once `podcertificate-controller` has the two CA pools, it self-creates the
`ClusterTrustBundle` objects (`kubectl get clustertrustbundles`) — nothing manual
there.

**Deliberately not in git:** these secrets hold generated private key material.
Regenerating a fresh PKI on every from-scratch bootstrap is fine — nothing outside
the cluster needs to trust these CAs.

**Where this lives:** `kagent-dev/substrate` repo, `hack/install-ate.sh` functions
`create_jwt_authority_pool_secret`, `create_actor_id_ca_pool_secret`,
`create_actor_id_ca_certs_secret`, `create_podcertificate_controller_cas`,
`create_api_authentication_config` (not linked from the chart's own docs — found by
reading the script directly).

---

## 3. RBAC: `use` on the podcert signers ✅ CONFIRMED REQUIRED — now in git

**What:** `flux/apps/base/substrate/substrate-operator/rbac-podcert-signer-use.yaml`
— a ClusterRole granting `use` on `certificates.k8s.io` `signers`
(`servicedns.podcert.ate.dev/identity`, `podidentity.podcert.ate.dev/identity`),
bound to the `ate-system` ServiceAccounts (`default`, `ate-api-server`,
`ate-controller`, `atenet-egress`, `atenet-router`, `atelet`).

**Why:** Kubernetes silently strips `signerName` — and the entire projected-volume
source — from a `podCertificate`/`clusterTrustBundle` volume unless the identity
that creates/server-side-applies the object holding the pod template has `use` on
that exact signer name. The chart ships `sign`/`attest` RBAC for the signer's own
controller (`podcert-ate-dev-signer` ClusterRole → `podcertificate-controller-system`
default SA) but grants **no `use` to anything**. Empirically isolated by:
1. Direct `SubjectAccessReview` calls (`kubectl auth can-i` mis-parses signer names
   containing `/` and always reports `no` — use a raw SAR, see below).
2. Impersonation tests: creating a Pod as `admin` or as an impersonated
   `kube-system:*-controller` identity preserved the field regardless of RBAC;
   granting RBAC to `flux-system:helm-controller` did nothing new (it already has
   `cluster-admin` via `cluster-reconciler-flux-system` — never the gap). Granting
   `use` to the workload ServiceAccounts, followed by a **fresh** Helm upgrade
   (`flux suspend`/`flux resume` — a stalled release's retry count does not reset
   on its own), is what actually re-stamped the StatefulSet/Deployment/DaemonSet
   templates correctly.

Check the current grant with a raw SAR (not `kubectl auth can-i`):
```bash
kubectl create --raw /apis/authorization.k8s.io/v1/subjectaccessreviews -f - <<'EOF' | jq .status
{"apiVersion":"authorization.k8s.io/v1","kind":"SubjectAccessReview","spec":{
  "user":"system:serviceaccount:ate-system:default",
  "resourceAttributes":{"group":"certificates.k8s.io","resource":"signers",
    "name":"servicedns.podcert.ate.dev/identity","verb":"use"}}}
EOF
```

**Where this lives:** `flux/apps/base/substrate/substrate-operator/rbac-podcert-signer-use.yaml`,
referenced from that directory's `kustomization.yaml` — reconciles automatically.

---

## 4. `ateomImage` version lockstep with the substrate chart ✅ CONFIRMED REQUIRED

**What:** `flux/apps/base/kagent/operator/helmrelease.yaml`,
`values.substrateWorkerPool.ateomImage` must be the **same version tag** as
`flux/apps/base/substrate/substrate-operator/helmrelease.yaml`'s chart `tag`
(currently both `0.0.21` / `v0.0.21`).

**Why:** `ate-controller` and `ateom-gvisor` are components of the same substrate
release; the worker CLI flags between them are not a stable cross-version
contract. Confirmed empirically: bumping substrate to `0.0.21` while
`ateomImage` stayed pinned at `v0.0.6` (a leftover pin from the unrelated
`docs/substrate-openclaw-talos.md` OpenClaw investigation) crash-looped **every**
`kagent-default` actor worker pod cluster-wide with `unknown flag:
--atunnel-listen-address` — a flag `ate-controller@0.0.21` started passing that
`ateom-gvisor@v0.0.6` doesn't understand.

**How:**
```bash
docker manifest inspect ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.21   # confirm the tag exists first
kubectl -n kagent patch helmrelease kagent --type=merge \
  -p '{"spec":{"values":{"substrateWorkerPool":{"ateomImage":"ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.21"}}}}'
```
then the same value committed to `flux/apps/base/kagent/operator/helmrelease.yaml`.

**Follow-up worth doing:** wire this tag to the same Renovate
`datasource=github-releases depName=kagent-dev/substrate` annotation already used
for the substrate chart's `OCIRepository` tag, so the two can't drift apart again
silently.

---

## 5. Privileged Pod Security Standard on `ate-system` / `kagent` ✅ CONFIRMED REQUIRED

**What:** both namespaces carry
`pod-security.kubernetes.io/enforce: privileged` (via this repo's
`namespace-privileged` infra component per `flux/CLAUDE.md`).

**Why:** confirmed by inspecting the live pod specs, not assumed:
- `atelet` (DaemonSet) runs with `securityContext.privileged: true` — outright
  rejected under `restricted` or `baseline` PSS.
- `ateom-gvisor` (kagent-default WorkerPool workers) runs non-privileged but with
  `capabilities.add: [NET_ADMIN, SYS_ADMIN, SYS_CHROOT, SYS_PTRACE, SETUID, SETGID,
  SETPCAP, DAC_OVERRIDE, FOWNER, CHOWN, MKNOD, NET_RAW, SETFCAP]` and
  `appArmorProfile.type: Unconfined` — `SYS_ADMIN` alone is blocked under
  `restricted`/`baseline`.

**Where this lives:** `flux/apps/dev/ate-system/kustomization.yaml` and
`flux/apps/dev/kagent/kustomization.yaml` `components:` entries referencing
`flux/infra/namespace-privileged`. Minor inconsistency worth fixing: the
`podcertificate-controller-system` namespace is created directly by the chart
(`templates/pod-certificate-controller.yaml`, a plain `kind: Namespace`), so it
never goes through this repo's namespace-templating pattern and carries no PSS
labels at all. Its one workload (`podcertificate-controller`) is `restricted`-
compatible anyway (`allowPrivilegeEscalation: false`, all capabilities dropped,
`readOnlyRootFilesystem: true`), so this is cosmetic, not a functional gap.

---

## 6. `user.max_user_namespaces` sysctl ✅ CONFIRMED REQUIRED — FIXED

**Update:** applied live to all 5 nodes and persisted to `talos-config` (see below).
Necessary but, as discovered in the same pass, **not sufficient on its own** — see
§6b for the second, still-open blocker found immediately after fixing this one.

**What's needed:** `machine.sysctls: {user.max_user_namespaces: "65536"}` (or
similar) in Talos machine config, **all 5 nodes** — actors can land on any worker.

**Why this is required (proven, not inherited from old docs):**
1. Live check on every node: `talosctl -n <ip> read /proc/sys/user/max_user_namespaces`
   → **`0`** on all 5 nodes (`control-01..03`, `worker-01..02`) as of this review.
2. Created a minimal test `ActorTemplate` (`kagent` namespace, `busybox`, targeting
   the existing healthy `kagent-default` WorkerPool) to force a real sandbox
   creation attempt — not just a pod-Ready check. Result: **deterministic,
   immediate failure**, retried forever:
   ```
   while creating pause container: while running `runsc create`: exit status 128
   ```
   (`ate-controller` reconciler logs, `kagent-default` worker logs — same error
   from every worker pod that picked up the request.)
3. Direct kernel-level proof, ruling out every other explanation (capabilities,
   AppArmor, seccomp — all already correctly configured per §5): a throwaway pod
   on `worker-01` running `unshare --user --map-root-user id` returned
   ```
   unshare: unshare(0x10000000): Operation not permitted
   ```
   — the exact, textbook symptom of `user.max_user_namespaces=0`. gVisor's
   `runsc` (platform `systrap`, no `/dev/kvm` on any node — see
   `docs/substrate-openclaw-talos.md`) creates a user namespace as part of
   sandbox setup; with the host-wide cap at zero, that syscall is refused
   regardless of the pod's own capabilities.

**Why this wasn't caught by the earlier "bring everything healthy" pass:** every
pod involved (`kagent-default-*` worker Deployments) reports `Running`/`1/1 Ready`
— the `ateom-gvisor` daemon itself starts fine and passes its own liveness/readiness
checks. It only fails when asked to actually create a sandboxed actor, which
nothing in a routine `kubectl get pods` sweep exercises. The existing `openclaw`
AgentHarness (namespace `kagent`) has been stuck since `2026-08-27T04:29:42Z` on an
unrelated `ActorTemplate` validation error (`spec.containers[0].env[0].value:
Required value` — a separate, pre-existing issue, out of scope here) and so never
got far enough to surface this either.

**Where the requirement was first documented (previous cluster, not this one):**
`docs/substrate-openclaw-talos.md` and `docs/2026-06-15-substrate-kagent-talos-deployment-writeup.md`
record `user.max_user_namespaces` being raised to `65536` on the **prior**
`talos-homelab` cluster (Talos v1.12.2, k8s v1.35.0). That cluster no longer
exists — this one (`admin@kubegit`, Talos v1.13.9, k8s v1.36.3) was built fresh and
never got the same sysctl. The requirement itself still holds; only the specific
cluster it was applied to changed. **Not yet added to `/Users/macbook/talos-config`
— this is the one action still pending from this review, deliberately not applied
without confirmation given this exact class of change caused a brief full-cluster
outage earlier (§1's "Gotcha").**

**Fix applied (this review, live):**
```bash
# Scoped patch — touches ONLY sysctls, deliberately not a full apply-config of
# the base file: worker.yaml/controlplane.yaml also currently differ from live
# node state on machine.install.image (see §6c) and applying the whole file
# would have bundled that in unasked-for.
export TALOSCONFIG=/Users/macbook/talos-config/talosconfig
for ip in 192.168.1.181 192.168.1.182 192.168.1.183 192.168.1.191 192.168.1.192; do
  talosctl --nodes "$ip" patch mc -p '{"machine":{"sysctls":{"user.max_user_namespaces":"65536"}}}'
  talosctl --nodes "$ip" read /proc/sys/user/max_user_namespaces   # expect 65536
done
```
Applied without a reboot on all 5 nodes; `kubectl get nodes` stayed `Ready`
throughout. Persisted to `/Users/macbook/talos-config/{controlplane,worker}.yaml`
(`machine.sysctls: {user.max_user_namespaces: "65536"}`, both files, with a comment)
and re-rendered into `rendered/*.yaml` via the documented
`talosctl machineconfig patch <base>.yaml --patch @<node>-patch-N.yaml -o rendered/<node>.yaml`
workflow, then re-validated (`talosctl validate --mode metal --strict`) — all 5 pass.

**Verification note:** the fix needed the `kagent-default` WorkerPool's existing
worker pods **restarted** (`kubectl -n kagent rollout restart deployment/kagent-default`)
before it took effect for sandbox creation — pods already running before the sysctl
change kept failing with the identical `unshare: Operation not permitted` symptom
even though the host-level `/proc/sys/user/max_user_namespaces` read `65536`; a
fresh pod on the same node with the same capability set succeeded immediately. Not
fully root-caused why the already-running pods didn't pick up the live host value
(worth a closer look if it recurs), but a rollout restart reliably clears it.

---

## 6b. cgroup v2 delegation ❌ NOT YET RESOLVED — second, independent blocker

**Found immediately after fixing §6, by re-running the same smoketest.** Raising
`user.max_user_namespaces` was real and necessary — the `unshare(CLONE_NEWUSER)`
step gVisor needs now succeeds, confirmed both by the standalone probe and by
`runsc`'s own debug log (`Configuring container with a new userns ... ` proceeds
without error). But actor creation still fails, now with a **different, later**
error:

```
FATAL ERROR: creating container: cannot set up cgroup for root: configuring cgroup:
open /sys/fs/cgroup/cgroup.subtree_control: read-only file system
```

**How this was captured:** `kubectl exec`/logs only ever showed ateom-gvisor's
wrapped `runsc create: exit status 128` — no detail. Got the real error by running
`runsc` directly: a throwaway debug pod on the same node, with the exact
`securityContext.capabilities` the `kagent-default` WorkerPool uses, hostPath-mounting
the same `/var/lib/ateom-gvisor` the real workers use (to reach the same `runsc`
binary), then invoking it by hand with `--debug --debug-log=/tmp/runsc.log create`
against a minimal OCI bundle.

**What this means:** gVisor's sandbox setup creates its own nested cgroup
(`/sys/fs/cgroup/<container>`) and needs to write to the parent's
`cgroup.subtree_control` to delegate controllers into it. Kubernetes/containerd
mount `/sys/fs/cgroup` **read-only** inside a container unless
`securityContext.privileged: true` — regardless of which individual Linux
capabilities (`SYS_ADMIN` etc.) are granted. The `kagent-default` WorkerPool's
`ateom-gvisor` container runs with `privileged: false` (confirmed:
`kubectl get pod <worker> -o jsonpath='{.spec.containers[0].securityContext.privileged}'`
→ `false`), which is presumably intentional — `atelet` (the DaemonSet) already
runs `privileged: true` where the chart authors decided that was warranted, and
didn't do the same for the per-actor worker pods.

**Not yet determined:** whether the intended fix is (a) `privileged: true` on the
`kagent-default`/every WorkerPool's pod template — a real security posture
change, since actor payloads run inside these pods, or (b) a `runsc`
flag/configuration (it exposes `--ignore-cgroups`, confirmed present in this
build's `config.go` flag dump) that `ateom-gvisor` could pass to skip cgroup
management entirely, if one exists as an operator-facing knob, or (c) a
containerd/Talos-level cgroup-delegation mechanism for unprivileged containers
that hasn't been located yet. Deliberately stopped here rather than unilaterally
flipping WorkerPool pods to privileged — that's a bigger decision than "add a
sysctl" and worth a explicit call.

**Reproduction (for whoever picks this up):**
```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: ate.dev/v1alpha1
kind: ActorTemplate
metadata: {name: sysctl-smoketest, namespace: kagent}
spec:
  sandboxClass: gvisor
  snapshotsConfig: {location: gs://ate-snapshots/kagent/sysctl-smoketest}
  containers:
  - {name: c, image: busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662, command: ["sleep","3600"]}
  resources: {limits: {cpu: 250m, memory: 128Mi}}
EOF
# watch: kubectl -n ate-system logs deploy/ate-controller --tail=20 | grep sysctl-smoketest
# clean up after: kubectl -n kagent delete actortemplate sysctl-smoketest
```

---

## 6c. Separately noticed, NOT acted on: `machine.install.image` drift

While rendering `rendered/*.yaml` to persist the §6 sysctl, the dry-run diff on
**every one of the 5 nodes** showed the live machine config still points
`machine.install.image` at the stock
`ghcr.io/siderolabs/installer:v1.13.9`, while `controlplane.yaml`/`worker.yaml`
(and thus `rendered/*.yaml`) already specify the Factory image
(`factory.talos.dev/metal-installer/613e...:v1.13.9`, with the `iscsi-tools`/
`util-linux-tools` extensions this repo's own `talos-config/README.md` documents
as required for Longhorn). This is **pre-existing drift, unrelated to
substrate/kagent**, not something this review introduced — flagged here because
it means those extensions may not actually be active despite the base config
believing they are. Deliberately not touched: fixing it means changing
`machine.install.image` cluster-wide, a separate decision from "add one sysctl,"
and this review's scope was substrate/kagent enablement specifically.

---

## 7. Two confirmed-dead values — remove or they'll mislead the next investigation

### 7a. ❌ `auth.jwt.issuer` in `flux/apps/base/substrate/substrate-operator/helmrelease.yaml`

Set to `https://192.168.1.180:6443` with a comment explaining Talos's OIDC issuer
quirk. **Verified dead:** `grep -rn "Values.auth" charts/substrate/templates/` on
chart `0.0.21` returns nothing — no template reads `.Values.auth` at all. The
*actual* JWT issuer wiring for `ate-api-server` comes from the
`ate-api-authentication` ConfigMap (§2), created imperatively, not from this Helm
value. The comment's underlying fact (Talos's OIDC issuer is the apiserver
endpoint, not `https://kubernetes.default.svc`) is correct and was reused when
building the ConfigMap — just not through this value.
**Recommendation:** delete the dead `auth:` block from the HelmRelease values, or
convert the comment into a pointer at §2 of this doc so a future reader doesn't
assume this is where the issuer is actually configured.

### 7b. ❌ `controller.substrate.runscAMD64URL` / `runscAMD64SHA256` in `flux/apps/base/kagent/operator/helmrelease.yaml`

Pins gVisor `runsc` nightly `2026-06-02` — the version
`docs/substrate-openclaw-talos.md` spent an entire investigation validating as the
one that both checkpoints *and* restores OpenClaw's node.js/V8 actor on amd64
`systrap`. **Verified dead against the currently-installed kagent chart
(`0.10.0-rc3`):** `grep -rln "runsc" charts/kagent/templates/` (both the top-level
chart and its bundled `charts/substrate` subchart, which is itself gated behind
`substrate.enabled: false` and never renders) returns **nothing**. This value maps
to no template field in this chart version — it was silently dropped by Helm as
an unrecognized key at every install/upgrade.

**What actually controls the gVisor build in effect today:** the *separately
deployed* `flux/apps/base/substrate` chart's default `SandboxConfig`
(`gvisor-default`, `templates/sandboxconfig-gvisor.yaml`), currently pointing at
`gs://gvisor/releases/release/20260803/{x86_64,aarch64}/gvisor.tar.bz2` — a full
release tarball, not a raw `runsc` binary, and **not** the validated `06-02`
nightly. This has never been tested against OpenClaw's node.js checkpoint/restore
path on this cluster.

**Consequence:** if/when §6 is fixed and the `openclaw` AgentHarness's separate,
pre-existing env-var validation error (see `docs/substrate-openclaw-open-items.md`)
is also resolved, OpenClaw restore may hit the original
`inconsistent private memory files on restore` amd64 bug again, because the
carefully-validated `06-02` pin is not actually in effect. **Recommendation:**
either find the current chart's real mechanism for overriding the gVisor release
asset (per-`SandboxConfig` `spec.assets.<arch>.gvisor.url/sha256` — this field is
CRD-native, not a Helm value, so it can be overridden with a plain
`kubectl patch sandboxconfig gvisor-default` or a small Kustomize patch in
`flux/apps/base/substrate/substrate-operator/`), or explicitly re-test OpenClaw
restore against `20260803` and drop the concern if it turns out fixed upstream.
Either way, delete the dead `runscAMD64URL/SHA256` values — they currently do
nothing but suggest a safety net that isn't there.

---

## 8. Things that were checked and found to need no changes

- **`substrate-crds` HelmRelease** (`flux/apps/base/substrate/substate-crds/`):
  installs `actortemplates.ate.dev`, `workerpools.ate.dev`,
  `sandboxconfigs.ate.dev`, `csidriverconfigs.ate.dev`. Confirmed present and in
  active use (`kubectl get crd | grep ate.dev`) — required, working, nothing to add.
- **Ingress/oauth2-proxy/WebSocket path to the kagent UI** — already verified
  working end-to-end; see `docs/substrate-openclaw-open-items.md` §"Dashboard over
  the ingress" for the two false-alarm investigations (stale `localStorage` socket
  URL, HTTP/2 probe artifact) already resolved there. No new findings this pass.
- **valkey-cluster stable addressing** (hostname announcement postRenderer patch
  in `flux/apps/base/substrate/substrate-operator/helmrelease.yaml`) — present,
  matches the documented fragility fix in `docs/substrate-openclaw-open-items.md`
  §4. Not re-tested this pass (no full-cluster restart occurred), carried over as
  still believed correct.

---

## Summary table

| # | Requirement | Status | Action needed |
|---|---|---|---|
| 1 | K8s feature gates (3x Beta + runtime-config) | ✅ Required, in place | None |
| 2 | 6 bootstrap secrets/configmap | ✅ Required, in place (live only) | None; re-run §2 commands after any full rebuild |
| 3 | RBAC `use` on podcert signers | ✅ Required, in place, in git | None |
| 4 | `ateomImage` version lockstep | ✅ Required, in place, in git | None; consider Renovate wiring |
| 5 | Privileged PSS on ate-system/kagent | ✅ Required, in place | None; optionally label `podcertificate-controller-system` for consistency |
| 6 | `user.max_user_namespaces` sysctl | ✅ Required, fixed this pass | None |
| 6b | cgroup v2 delegation for `runsc` | ❌ **Required, still broken** | **Decide: privileged WorkerPool pods, an `--ignore-cgroups`-equivalent knob, or a containerd/Talos delegation mechanism** |
| 6c | `machine.install.image` drift (pre-existing, unrelated) | ℹ️ Noticed, not acted on | Separate decision — Longhorn extensions may not be active |
| 7a | `auth.jwt.issuer` HelmRelease value | ❌ Dead | Remove or repoint comment |
| 7b | `runscAMD64URL/SHA256` HelmRelease value | ❌ Dead | Remove; find real override mechanism if OpenClaw restore still needs a pin |
