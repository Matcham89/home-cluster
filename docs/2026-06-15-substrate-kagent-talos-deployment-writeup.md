# Deployment Write-up: kagent AgentHarness on Agent Substrate (Talos homelab)

**Date:** 2026-06-15 · **Cluster:** `talos-homelab` (Talos v1.12.2, Kubernetes v1.35.0, Flux CD, GitOps)
**Goal:** Run an OpenClaw/NemoClaw agent as a substrate-sandboxed **AgentHarness** through kagent.

This documents everything attempted, the issues hit, the decisions made, and the fixes — across CNPG/Authentik, cluster health, Agent Substrate, kagent, gVisor, and Talos.

---

## 0. Environment / stack

- **Talos Linux** v1.12.2 (immutable), 3 control planes (`.181–.183`), 3 workers (`.191–.193`), API VIP `192.168.1.180`.
- **Kubernetes** v1.35.0, **Flux CD** GitOps from `home-cluster` repo; PodSecurity enforced per-namespace via infra components.
- **Agent Substrate** (`kagent-dev/substrate`) chart `0.0.6` in `ate-system` — `ate-api`, `ate-controller`, `atelet`, `atenet`, `rustfs` (S3 snapshot store), `valkey` (cluster), gVisor (`ateom-gvisor`) workers.
- **kagent** `0.9.7` — operator/controller, agents, and the `AgentHarness` CRD (`kagent.dev/v1alpha2`) with substrate + openshell runtimes.

---

## 1. Authentik down — CNPG superuser password drift (resolved)

**Symptom:** `authentik-operator-server` CrashLoopBackOff — `password authentication failed for user "postgres"` against the CNPG `postgres-cluster`.

**Root cause:** the live `postgres` role password had drifted from the `postgres-superuser` secret. CNPG only reconciles the superuser password when the secret's `resourceVersion` changes; ESO refreshes from Bitwarden with an unchanged value, so the drift never self-healed. The secret was also `Opaque` (CNPG expects `kubernetes.io/basic-auth`).

**Immediate fix:** re-synced the role to the secret via `ALTER ROLE postgres WITH PASSWORD …` over the in-pod peer-auth socket.

**Durable fix (decision: Path B — dedicated roles):** gave authentik and n8n their own **CNPG `managed.roles`** (`authentik`, `n8n`, non-superuser, login) with `passwordSecret` (basic-auth, `cnpg.io/reload: "true"`), continuously reconciled. Migrated DB ownership with a **scoped DO block** (deliberately NOT `REASSIGN OWNED BY postgres`, which would have reassigned *all* shared databases). Repointed app ExternalSecrets to new Bitwarden items. Apps now connect as their own roles; superuser drift can no longer take them down. Verified zero `postgres` connections from the apps.

---

## 2. Cluster-health sweep — Valkey cluster recovery (recurring)

**Symptom:** `flux get` showed `substrate` HelmRelease failed → cascaded to the entire kagent dependency chain. Root: `ate-api-server` CrashLoop — couldn't reach Valkey (`dial tcp <old-ip>:6379: no route to host`).

**Root cause:** all 6 valkey pods restarted and got new IPs, but the cluster's persisted `nodes.conf` still advertised the old IPs (`cluster_state:fail`, slots PFAIL). Valkey cluster has **no stable addressing** (no `cluster-announce-ip`/StatefulSet-DNS), so a simultaneous IP change bricks it.

**Fix:** `CLUSTER RESET HARD` on **all 6 nodes together** (resetting them one-by-one lets the not-yet-reset nodes re-teach the stale topology) → `valkey-cli --cluster create` with current IPs → restart `ate-api`/`atelet`. Also discovered `ate-api` caches stale topology and **leaked `actor:*`/`worker:*` keys** cause "no free workers"; recover with `flushall` on masters + worker Deployment restart.

**Status:** recovered, but **fragile** — recurs on pod IP changes. Needs a chart-level stable-addressing fix (tracked separately).

---

## 3. Agent Substrate / kagent AgentHarness — the deployment saga

Pursuing the goal (OpenClaw/NemoClaw on substrate), we cleared a chain of independent blockers, each diagnosed from logs:

| # | Issue | Root cause | Fix | Layer |
|---|---|---|---|---|
| 1 | substrate `ate-api` CrashLoop | Valkey bricked (see §2) | reset/reform valkey | runtime |
| 2 | `ate-api` rejects controller token: `invalid bearer token: unexpected issuer` | Talos mints SA tokens with issuer `https://192.168.1.180:6443`; chart defaulted to `https://kubernetes.default.svc.cluster.local` | set `auth.jwt.issuer` in substrate HelmRelease values | GitOps config |
| 3 | `kagent-agent-harness` rejected at admission | `AgentHarness` CRD (`runtime: substrate`) requires `runtime: substrate` set + exactly one of `gatewayToken`/`gatewayTokenSecretRef` (CEL) | added `runtime: substrate` + `gatewayTokenSecretRef` (self-issued bearer token via ESO/Bitwarden) | GitOps config |
| 4 | worker Deployment ImagePullBackOff | operator `substrateWorkerPool.ateomImage` pinned to kagent version `v0.9.7` (doesn't exist); ateom-gvisor tracks the **substrate** version | set tag `v0.0.6` | GitOps config |
| 5 | worker pods rejected by PodSecurity | `ateom-gvisor` needs privileged+hostPath; `kagent` ns enforced baseline | switched kagent ns to `namespace-privileged` (same as OpenShell used) | GitOps config |
| 6 | gVisor sandbox create: `fork/exec /proc/self/exe: no space left on device` (even pause container, any memory size) | **Talos defaults `user.max_user_namespaces = 0`** — `clone(CLONE_NEWUSER)` returns ENOSPC; gVisor-in-pod needs user namespaces | Talos `machine.sysctls.user.max_user_namespaces = "65536"` (live `talosctl patch mc --mode=no-reboot`) | **Talos node config** |
| 7 | "no free workers available" | leaked golden actors + a dead worker key in valkey from prior failed attempts | `flushall` + worker Deployment restart | runtime |
| 8 | OpenClaw actor restore fails: `inconsistent private memory files on restore` | gVisor multi-container checkpoint/restore can't reconcile the **node.js** openclaw private memory | **UNRESOLVED — upstream** (see §5 + proposal doc) | upstream gVisor/substrate |

**Decisions / dead ends along the way:**
- Initially hypothesized the gVisor ENOSPC was a `/dev/shm` (64Mi default) limit → forked substrate's `workerpool_controller.go` to add a 1Gi `/dev/shm` + explicit resources to ateom workers, built a custom image (`docker.io/matcham89/atecontroller:0.0.6-shmfix`) via `ko`, wired it through a Flux HelmRelease **postRenderer**. **This was NOT the root cause** (sysctl was) — but it's reasonable hygiene and stays in place.
- Confirmed there is **no non-gVisor / "vanilla k8s" actor runtime** in substrate (the "#3 vanilla k8s" commit is about *installing* substrate on plain k8s, not actor runtime). Every actor goes through gVisor.
- Confirmed kagent **substrate** runtime supports only `openclaw`/`nemoclaw` backends; **hermes runs only on the openshell runtime**. (We pivoted the harness to `nemoclaw`.)
- OpenShell was decommissioned (removed `apps/base/openshell` + `apps/dev/openshell`, stripped operator `OPENSHELL_*` env); cleared stuck `agent-harness-backend-cleanup` finalizers left by removing the backend before deleting the harness.

**Proof substrate works:** a minimal **Go** actor (`demos/counter`, built `docker.io/matcham89/counter:demo`) deployed as a raw `ActorTemplate` reached **Ready** (golden snapshot in rustfs), and a logical actor **resumed to `STATUS_RUNNING`** (full checkpoint **and** restore). So the substrate model is sound; only the node.js OpenClaw workload fails restore.

---

## 4. Talos config management — migrated to talhelper

**Problem found:** the `home-cluster-talos-config` repo stored **stale single-node snapshots** (a `worker.yaml` = worker-03 @ kubelet v1.34.1; `controlplane.yaml` = control-03). A dry-run `apply-config` proved applying them would rename nodes / change IPs / downgrade kubelet. The `talosconfig` endpoints (`.181–.183`) were unreachable from the admin laptop (only the VIP `.180` works). The README documented decrypt/verify but no **apply** workflow.

**Decision:** adopt **talhelper** as the declarative source of truth.

**Done (by a handed-off agent, dry-run-verified, no live apply):** authored `talconfig.yaml` (all 6 nodes, correct identities, Talos v1.12.2/kubelet v1.35.0), `patches/` (incl. `user.max_user_namespaces: "65536"`), imported existing PKI into `talsecret.sops.yaml` (never regenerated), fixed endpoints → `.180`, rewrote the README. Per-node `apply-config --dry-run` shows no regression; the sysctl is already live and now captured declaratively (a full multi-doc apply would reboot due to a benign network-format migration — optional, maintenance-window).

---

## 5. The one unresolved blocker (the reason for the upstream proposal)

OpenClaw/NemoClaw on substrate gets all the way through: **boot ✅ → golden-snapshot checkpoint ✅ → ActorTemplate Ready ✅**, then the running harness actor **fails to restore**:

```
runsc restore openclaw: inconsistent private memory files on restore:
  savedMFOwners = [pause:/], mfmap = map[openclaw:/:unwasteSmall:, pause:/:unwasteSmall:]
```

- Substrate checkpoints only the `pause` (sandbox root) and restores `pause`+`openclaw` from it. gVisor's checkpoint/restore is single-container-oriented; it can't reconcile the **node.js** app container's private memory across that boundary.
- **The runsc version is coupled to substrate's C/R code:** bumping to nightly `2026-06-13` (from the pinned `2026-05-19`) *broke checkpoint outright* — so version juggling is a dead end.
- **Proven node-specific:** the Go `hello-counter` actor checkpoints **and restores** (`STATUS_RUNNING`). Only the node.js OpenClaw workload fails. → It's not substrate's multi-container mechanism; it's gVisor C/R vs node/V8 memory.

This requires an upstream fix in `kagent-dev/substrate` — see `PROPOSAL-kagent-substrate-openclaw-checkpoint-restore.md`.

---

## Artifacts produced this session
- CNPG dedicated roles + ExternalSecrets (authentik/n8n) — merged to `home-cluster`.
- Substrate fixes: JWT issuer, ateom image tag, kagent privileged ns, LimitRange override, custom `atecontroller` image + postRenderer (`/dev/shm`), gateway-token ESO.
- Talos: `machine.sysctls.user.max_user_namespaces=65536` (live + talhelper-captured).
- talhelper migration of the Talos config repo.
- Custom images on Docker Hub: `matcham89/atecontroller:0.0.6-shmfix`, `matcham89/counter:demo`.
- `hello-counter` ActorTemplate (working substrate proof, left deployed).
- Upstream proposal doc (next file).
