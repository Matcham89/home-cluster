# Substrate (kagent-dev/substrate) bootstrap requirements

**Read this before (re-)installing `flux/apps/base/substrate/` on a fresh cluster.**
None of the steps below are automated by the Helm chart, by Flux, or by
`talos-config` — they are one-time, cluster-scoped, imperative prerequisites. Full
incident writeup: `docs/2026-08-27-ate-system-clustertrustbundle-investigation.md`.

## 1. Kubernetes feature gates (Talos-specific)

The chart requires three Beta feature gates plus a runtime API, none of which Talos
enables by default. These **are** persisted in `/Users/macbook/talos-config`
(`controlplane.yaml` / `worker.yaml` `extraArgs`), so a from-scratch rebuild from that
repo already has them — nothing to do here unless bootstrapping a brand new
`talos-config`.

- kube-apiserver: `feature-gates: ClusterTrustBundle=true,ClusterTrustBundleProjection=true,PodCertificateRequest=true`
  and `runtime-config: certificates.k8s.io/v1beta1=true`
- kubelet (all nodes): `feature-gates: ClusterTrustBundle=true,ClusterTrustBundleProjection=true,PodCertificateRequest=true`

**Gotcha:** `ClusterTrustBundleProjection` and `PodCertificateRequest` both depend on
`ClusterTrustBundle`. Set all three in the same patch — enabling a dependent gate
without its dependency crash-loops kubelet on every node simultaneously.

## 2. Bootstrap secrets and ConfigMap (NOT persisted anywhere in git)

The chart mounts these but never creates them (its own `README.md` doesn't mention
them either — this was reverse-engineered from `kagent-dev/substrate`'s
`hack/install-ate.sh`). They contain generated private key material, so they are
**not** git-tracked; regenerate them with the commands below any time
`ate-system` is bootstrapped from scratch (a fresh PKI each time is fine — nothing
outside the cluster needs to trust these CAs).

Build the CLI once (from a checkout of `kagent-dev/substrate`, any recent commit —
these subcommands have been stable):

```bash
git clone https://github.com/kagent-dev/substrate.git /tmp/substrate-src
cd /tmp/substrate-src
go build -o /tmp/kubectl-ate ./cmd/kubectl-ate
```

Then, against the target cluster's *current* kubeconfig context:

```bash
# actor-identity JWT authority (used by ate-api-server to mint/verify actor JWTs)
/tmp/kubectl-ate admin make-jwt-pool --key-id=1 --name=actor-id-jwt-pool --secret-namespace=ate-system

# actor-identity CA (root+key; signs actor client certs)
/tmp/kubectl-ate admin make-ca-pool --ca-id=1 --name=actor-id-ca-pool --secret-namespace=ate-system

# the podcertificate-controller's own signing CAs — one per custom signer
kubectl create namespace podcertificate-controller-system --dry-run=client -o yaml | kubectl apply -f -
/tmp/kubectl-ate admin make-ca-pool --ca-id=1 --name=service-dns-ca-pool  --secret-namespace=podcertificate-controller-system
/tmp/kubectl-ate admin make-ca-pool --ca-id=1 --name=pod-identity-ca-pool --secret-namespace=podcertificate-controller-system

# actor-id-ca-certs: cert-only copy of actor-id-ca-pool's root, for atenet-egress to
# validate actor client certs (derived, so it must run after actor-id-ca-pool exists)
actorid_root=$(
  kubectl get secret -n ate-system actor-id-ca-pool -o jsonpath='{.data.pool}' | base64 --decode \
    | grep -o '"RootCertificateDER":"[^"]*' | sed 's/"RootCertificateDER":"//' \
    | base64 --decode | openssl x509 -inform der -outform pem
)
kubectl create secret generic actor-id-ca-certs --from-literal=ca.crt="${actorid_root}" \
  -n ate-system --dry-run=client -o yaml | kubectl apply -f -

# ate-api-server's JWT authentication config — issuer must match the live cluster's
# OIDC discovery endpoint (Talos mints SA tokens with the apiserver endpoint as
# issuer, not the stock in-cluster URL)
jwt_issuer=$(kubectl get --raw /.well-known/openid-configuration | grep -o '"issuer":"[^"]*' | sed 's/"issuer":"//')
kubectl create configmap -n ate-system ate-api-authentication \
  --from-literal=authentication.yaml="$(printf 'actorIdentityJWTProvider: kubernetes\njwtProviders:\n- name: kubernetes\n  issuer: %s\n  audiences: [api.ate-system.svc]\n' "${jwt_issuer}")" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Once `podcertificate-controller` is running with the two CA pool secrets above, it
self-creates the `ClusterTrustBundle` objects (`kubectl get clustertrustbundles`) —
nothing to apply manually there.

## 3. RBAC: `use` on the podcert signers

**This is committed to git** —
`flux/apps/base/substrate/substrate-operator/rbac-podcert-signer-use.yaml` — so it
applies automatically on every reconcile. Documented here because it's easy to
mistake for chart-provided RBAC and isn't (the chart only grants `sign`/`attest` to
the signer's own controller, never `use` to anything).

Kubernetes silently strips `signerName` (and the whole projected-volume source) from
any `podCertificate`/`clusterTrustBundle` projection unless the identity that
*creates or server-side-applies* the object containing the pod template has `use` on
that exact signer name. For plain `kubectl apply`/`create` of a Pod, that's the
caller. For a Flux `HelmRelease` with no `spec.serviceAccountName` override — as
`substrate` has — that's **`system:serviceaccount:flux-system:helm-controller`**
(already `cluster-admin` in this repo via `cluster-reconciler-flux-system`, so no
extra grant needed for it specifically). What's missing without this file is `use`
for the **workload's own ServiceAccount**, needed any time something other than
`helm-controller` creates/updates one of these pods (e.g. `kubectl delete pod` to
force a StatefulSet/DaemonSet to re-create with a corrected template, or the
StatefulSet/DaemonSet controller itself doing routine replacement).

If you ever see `sources: [{}]` where a `clusterTrustBundle`/`podCertificate`
source should be, check this first:

```bash
kubectl create --raw /apis/authorization.k8s.io/v1/subjectaccessreviews -f - <<'EOF' | jq .status
{"apiVersion":"authorization.k8s.io/v1","kind":"SubjectAccessReview","spec":{
  "user":"system:serviceaccount:ate-system:default",
  "resourceAttributes":{"group":"certificates.k8s.io","resource":"signers",
    "name":"servicedns.podcert.ate.dev/identity","verb":"use"}}}
EOF
```

(`kubectl auth can-i use signers/<signer>/identity` mis-parses the signer name's `/`
and always reports `no` — use a raw SubjectAccessReview instead, as above.)

**If the field is already stripped in a live StatefulSet/Deployment/DaemonSet
template**, granting RBAC alone does not retroactively fix it — the broken template
is already stored. Force a fresh Helm upgrade to re-stamp it:

```bash
flux suspend helmrelease substrate -n ate-system
flux resume helmrelease substrate -n ate-system --timeout=120s
```

(A plain `flux resume` on an already-unsuspended release is a no-op — the
suspend/resume toggle is what resets Flux's "exceeded retries" stalled state.) Then
`kubectl delete pod` any StatefulSet/DaemonSet-owned pods that predate the fix —
unlike Deployments, they don't get proactively replaced on a template change alone.

## 4. `ateomImage` must track the substrate chart version

`flux/apps/base/kagent/operator/helmrelease.yaml`'s
`values.substrateWorkerPool.ateomImage` pins a specific
`ghcr.io/kagent-dev/substrate/ateom-gvisor` tag. **This must be bumped in lockstep
with `flux/apps/base/substrate/substrate-operator/helmrelease.yaml`'s chart
version** — `ate-controller` and `ateom-gvisor` are both substrate components and
the wire protocol between them (worker CLI flags) is not guaranteed stable across
versions. A stale pin here crash-loops every actor pod in every WorkerPool with an
`unknown flag` error from `ateom-gvisor`, cluster-wide, with no relation to whatever
substrate/kagent change actually triggered it — easy to misdiagnose. Verify a tag
exists before bumping: `docker manifest inspect ghcr.io/kagent-dev/substrate/ateom-gvisor:v<version>`.
