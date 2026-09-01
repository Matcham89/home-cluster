# Proposal: Fix OpenClaw/NemoClaw AgentHarness restore on Agent Substrate (gVisor multi-container C/R of node.js)

**For:** `kagent-dev/substrate` (+ `kagent-dev/kagent`) maintainers
**Author context:** contributor; reproduced on a self-hosted Talos/k8s cluster.
**TL;DR:** An OpenClaw/NemoClaw `AgentHarness` on the **substrate** runtime boots and its golden snapshot **checkpoints** successfully, but **restoring** the running actor fails in gVisor with `inconsistent private memory files on restore`. A Go actor checkpoints **and** restores fine on the same cluster, so the defect is specific to **gVisor checkpoint/restore of the node.js (V8) workload** under substrate's "checkpoint root, restore all containers" model — not substrate's multi-container mechanism in general.

---

## 1. Problem statement

`AgentHarness{runtime: substrate, backend: nemoclaw}` (and `openclaw`) never reaches `Ready`. Conditions:
```
ActorTemplateReady=True   # golden snapshot created OK
ActorReady=False          # "actor is resuming" — never completes
```
The ateom worker logs show the restore of the `openclaw` application sub-container failing:
```
runsc restore openclaw (exit status 128):
  FATAL ERROR: starting sub-container [...openclaw gateway run ...]:
  inconsistent private memory files on restore:
    savedMFOwners = [pause:/], mfmap = map[openclaw:/:unwasteSmall:, pause:/:unwasteSmall:]
```

## 2. Environment

- Agent Substrate chart `0.0.6`; kagent `0.9.7`.
- gVisor `runsc` nightly **2026-05-19** (the value pinned in `kagent` `--substrate-runsc-amd64-url` and substrate's demo/docs), platform `systrap`, `-allow-connected-on-save` set.
- Talos v1.12.2 / k8s v1.35.0, `ateom-gvisor:v0.0.6`. `user.max_user_namespaces` raised to 65536 (required for gVisor-in-pod on Talos).
- Backend image: `ghcr.io/kagent-dev/nemoclaw/sandbox-base` (node.js/TypeScript OpenClaw gateway).

## 3. Reproduction

1. Healthy substrate + a `WorkerPool`. Create `AgentHarness` `nemoclaw`/`openclaw`, `runtime: substrate`, valid `gatewayTokenSecretRef`, `modelConfigRef`.
2. Observe: `RunWorkload` (boot) OK → `CheckpointWorkload` OK (snapshot lands in the snapshot store) → ActorTemplate `Ready`.
3. The harness creates the logical actor and `ResumeActor` → `RestoreWorkload` → **fails** with the error above; harness stuck `ActorReady=False`.

**Control (passes):** a Go `ActorTemplate` (`demos/counter`) → `create actor` + `resume actor` → `STATUS_RUNNING`. Checkpoint **and** restore both succeed. This isolates the defect to the node.js workload's memory, not the substrate C/R flow.

## 4. Root-cause analysis

- Substrate's model (`cmd/ateom-gvisor/runsc.go` / `main.go`): a sandbox runs **`pause` (root) + the app sub-container**; substrate **checkpoints only `pause`** (`cmdCheckpoint(ctx, "pause", …)`) and **restores each container** from that one image (per the in-code comment).
- gVisor's checkpoint/restore is documented as single-container-oriented (see gVisor C/R docs and issue #1956). The error is gVisor-internal memory-file (MF) ownership accounting: the checkpoint recorded MF ownership for `pause:/` only, while restore of the `openclaw` sub-container expects per-sub-container private MF (`mfmap`) — they don't reconcile.
- This only manifests for **node.js/V8** (JIT executable pages, large/dirty private anonymous mappings, possibly `memfd`/`MAP_SHARED`). A Go binary's simpler memory layout restores cleanly.
- **runsc version is tightly coupled** to substrate's C/R image format: bumping to nightly `2026-06-13` broke `checkpoint` outright (`checkpoint failed … file exists` / changed image-path semantics). So "just upgrade runsc" is not a safe fix.

## 5. Proposed work (options, roughly in order of leverage)

**A. Reproduce + bisect the gVisor C/R of a node workload (highest priority).**
Add a minimal node.js actor to substrate's e2e/benchmark suite (today only the **Go** counter is exercised). Determine whether the failure is:
  - the multi-container "checkpoint root / restore sub-containers" pattern with sub-container **private** memory, or
  - a node/V8-specific memory feature gVisor C/R mishandles.

**B. Engage gVisor upstream with a minimal repro.**
If it's a gVisor C/R bug for node/V8 private memory under multi-container restore, file it (ref #1956) with a tiny node "hello gateway" container. Identify the **runsc version** in which substrate's checkpoint-root/restore-all actually works for node, and **pin + document** it (the kagent operator already exposes `--substrate-runsc-amd64-url/sha256`, but it's effectively a tested, coupled dependency).

**C. Evaluate checkpointing the full sandbox (not just `pause`).**
If gVisor can checkpoint/restore all containers' private memory coherently with a different invocation, substrate's `cmdCheckpoint`/`cmdRestore` may need to capture sub-container MF ownership so restore can map it. (Design question for maintainers who know the gVisor C/R contract.)

**D. Implement the roadmap "disk-only resume / cold-start" fallback.**
For backends whose process memory can't be RAM-checkpointed, support restoring **filesystem state only** and cold-booting the process. This would make node-based backends (openclaw/nemoclaw/hermes are all node/TS) usable on substrate without RAM C/R, even if gVisor C/R never fully supports them. Could be an `AgentHarness`/`ActorTemplate` opt-in (`resumePolicy: diskOnly`).

**E. Surface the failure in `AgentHarness` status.**
Today the gVisor restore error is buried in ateom logs; the harness just reports `actor is resuming`. Bubble the underlying `RestoreWorkload` error into a condition/event so operators can diagnose without digging into worker pods.

**F. Document the runtime/runtime-backend support matrix.**
Make explicit that substrate backends are node/TS (openclaw/nemoclaw/hermes), that hermes is openshell-only, and the current C/R support status per backend.

## 6. Acceptance / definition of done

- A node.js OpenClaw/NemoClaw `AgentHarness` on substrate reaches `Ready` and serves traffic after restore (or a documented `diskOnly` fallback does).
- CI covers a node actor through full **checkpoint + restore** (not just the Go counter).
- The supported/pinned runsc version for node backends is documented and enforced.

## 7. Open questions (cheap experiments to bound the bug)

- **CPython vs node:** does a plain Python actor restore cleanly (like Go)? If yes, the bug is bounded to V8/node memory, not "any interpreter." (We proved Go restores; Python is the obvious next probe — its memory model is closer to Go than to V8.)
- Which gVisor `runsc` version, if any, restores the substrate pause+node multi-container layout?
- Is `-allow-connected-on-save` sufficient, or are additional save/restore flags needed for node's memory mappings?

## Appendix: exact log excerpts

Checkpoint (OK): `CheckpointWorkload … err:null` → snapshot `checkpoint.img.zstd`, `pages.img.zstd`, `pages_meta.img.zstd` in the store.
Restore (FAIL): `RestoreWorkload … while starting "openclaw" application container: while running 'runsc restore': exit status 128` with `inconsistent private memory files on restore: savedMFOwners=[pause:/], mfmap=map[openclaw:/:unwasteSmall:, pause:/:unwasteSmall:]`.
Control (Go counter): `create actor` → `STATUS_SUSPENDED`; `resume actor` → `STATUS_RUNNING` (checkpoint **and** restore succeed).

---

## 8. Repro update — kagent 0.9.8 + substrate 0.0.6 (2026-06-16)

Re-reproduced on the same Talos cluster after the kagent `0.9.7 → 0.9.8` bump. Two things worth adding
upstream:

**(a) The configuration is the documented happy path.** The kagent-generated `ActorTemplate` is
byte-for-byte identical to the official `examples/substrate-openclaw/README.md` (same
`nemoclaw/sandbox-base@sha256:d52bee…3a3b4`, same runsc nightly `2026-05-19`, same
`gke-release/pause@sha256:bcbd57…`, `workerPoolRef: kagent-default`). The chart's `ate-api` secret-RBAC
Role/RoleBinding is present. So this is **not** a misconfiguration — it is the intended setup failing.

**(b) The failure now surfaces as a hang/timeout, not a clean error.** On 0.9.8 the resume fails at:
```
/ateapi.Control/ResumeActor (ahr-kagent-<harness>):
  workflow failed at step CallAteletRestore:
  while creating workload from golden snapshot:
  rpc error: code = DeadlineExceeded desc = context deadline exceeded   (~28s)
```
i.e. the `runsc restore` of the node.js `openclaw` app container **stalls past the ateom/atelet restore
deadline** rather than returning the earlier `inconsistent private memory files … exit status 128`.
Likely the same root cause (gVisor can't reconcile V8 private memory under checkpoint-root/restore-all),
now manifesting as a hang.

**(c) Control re-confirmed, live.** On the *same* workers and the *same* gVisor `systrap` platform, the
**Go** `ui-substrate-agent` actor restored successfully multiple times in the same window
(`RestoreWorkload … err:null`, 0.5–2.2s). The defect remains bounded to the node.js workload, not the
substrate C/R flow or the environment.

**Environment note for triage:** this is a Talos **gVisor-in-pod** deployment on the `systrap` platform
(no `/dev/kvm` exposed to workers).

**(d) Kind E2E reproduction SUCCEEDS — this bounds the bug sharply (2026-06-16).** We ran the full
upstream `examples/substrate-openclaw` flow on a local Kind cluster (Apple Silicon, Docker Desktop):
substrate **repo HEAD** + kagent built from source, `ateom-gvisor` + control plane for `linux/arm64`.
The OpenClaw `AgentHarness` reached `ActorRunning` in ~45s — the node.js actor **checkpointed and
restored** (`runsc restore … container=openclaw` → `Actor restored`, `RestoreWorkload err:null`,
`elapsed-time 948ms`), on gVisor **`Platform: systrap`** (same as Talos, no `/dev/kvm`).

This **kills** several hypotheses: it is not "gVisor can't C/R node.js/V8", not the `systrap` platform,
not the rustfs snapshot store, not the pause+app multi-container model — all identical and working on
Kind. The Talos failure is therefore bounded to the axes that differ between the two runs:
- **ateom/substrate code version**: Talos released `v0.0.6` vs Kind repo **HEAD (+18 commits**, incl.
  `ef1c9ed Fix gvisor cleanup issue`, `b923428 Fix ateom cleanup failure handling`).
- **CPU arch**: Talos **amd64** vs Kind **arm64** (different `runsc` binary + V8 memory layout) — the
  `inconsistent private memory files` MF-ownership error may be amd64-specific.
- **Host kernel**: Talos kernel (bare metal) vs Docker Desktop `6.6.119-virt`.

**Sharpened questions for maintainers:** (1) ~~Is there a node-relevant checkpoint/restore fix between
`v0.0.6` and HEAD?~~ — **answered: NO (see (e)).** (2) Is the `inconsistent private memory files` restore
failure **amd64-specific** under `systrap`? (Confirmed success only on arm64.) Reproduction details and a
variable-by-variable comparison table: `substrate-openclaw-talos.md` §6–7.

**(e) ateom HEAD does NOT fix it on amd64 — the failure is architecture-bound (2026-06-16).** Built
`ateom-gvisor` from substrate **HEAD (`6d7b14d`)** for `linux/amd64` and ran it on the Talos worker pool
(same runsc nightly `2026-05-19`, `release-20260511.0-42-ga7924c4ef10d`, `amd64`). The OpenClaw resume
**still fails with the identical error**:
```
runsc restore: exit status 128 — inconsistent private memory files on restore:
  savedMFOwners = [pause:/], mfmap = map[openclaw:/:unwasteSmall: ...]
```
With ateom code now **byte-identical** to the Kind run that succeeds, the only remaining differences are
**CPU arch (amd64 Talos vs arm64 Kind)** and host kernel. **Conclusion: the OpenClaw node.js/V8 C/R works
under gVisor `systrap` on arm64 and fails on amd64 with the MF-ownership error — it is not a substrate
version issue.** This strongly suggests an **amd64-specific gVisor checkpoint/restore defect** in the
pinned `2026-05-19` runsc (or an amd64-only interaction in substrate's checkpoint-root/restore-sub-
containers model). Recommended upstream focus: gVisor C/R of multi-container private memory on **amd64
`systrap`** with a node/V8 sub-container.

**(f) RESOLVED on amd64 by a later runsc — the gVisor fix landed in `(2026-05-26, 2026-06-02]`
(2026-06-16).** An amd64 runsc nightly sweep confirmed: `2026-05-19` and `2026-05-26` still fail restore
with `inconsistent private memory files`; **`2026-06-02` checkpoints AND restores the node.js OpenClaw
actor successfully** on the same Talos amd64 cluster (`Ready=True / ActorRunning`). `2026-06-02` is also
before the `2026-06-13` checkpoint regression, giving a working window. So the defect was a genuine
**amd64 gVisor C/R bug fixed upstream in gVisor between 05-26 and 06-02** — not a substrate issue. **For
the substrate maintainers: bumping the pinned `--substrate-runsc-amd64-url` default from `2026-05-19` to
`2026-06-02` (or validating a current nightly that both checkpoints and restores) would unblock amd64
node backends.** Independently confirmed working on arm64 since at least `2026-05-19`.
