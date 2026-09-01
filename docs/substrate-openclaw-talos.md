# OpenClaw on Agent Substrate — Talos homelab notes

**Status:** 2026-06-16 · kagent `0.9.8` · substrate chart `0.0.6` · runsc nightly `2026-05-19` · gVisor platform `systrap`
**Cluster:** `talos-homelab` (Talos v1.12.2, k8s v1.35.0, Flux GitOps)

> **✅ RESOLVED (2026-06-16): pin amd64 runsc to nightly `2026-06-02`.** OpenClaw node.js
> checkpoint+restore now works on Talos amd64 (`openclaw-final` → `Ready=True / ActorRunning`, ~104s).
> Root cause was an **amd64-specific gVisor checkpoint/restore bug**, fixed in a gVisor nightly between
> `2026-05-26` (still fails) and `2026-06-02` (restores); `06-02` checkpoint still works (it breaks at
> `06-13`). Fix = set `controller.substrate.runscAMD64URL/SHA256` to `2026-06-02` in the kagent operator
> HelmRelease (staged in `flux/apps/base/kagent/operator/helmrelease.yaml`). Full path below.
>
> **How we got here:** Kind E2E succeeded (§6) → isolated to amd64 by rebuilding ateom HEAD on Talos and
> still failing (§7) → runsc amd64 nightly sweep found `2026-06-02` fixes it (§8).

This is the Talos-specific companion to the upstream guide
[`kagent-dev/kagent` `examples/substrate-openclaw/README.md`](https://github.com/kagent-dev/kagent/blob/main/examples/substrate-openclaw/README.md).
The upstream README targets a **Kind** cluster and is **silent on checkpoint/restore** — it documents
deployment, not a demonstrated successful resume. This doc records what actually happens on our
Talos/gVisor-in-pod setup and what we can try.

---

## 1. What the upstream README confirms (config layer is correct)

Our live, kagent-generated `ActorTemplate` is **byte-for-byte** the documented happy path:

| Element | Upstream README | Our cluster |
|---|---|---|
| openclaw image | `nemoclaw/sandbox-base@sha256:d52bee…3a3b4` | identical ✅ |
| runsc | `gs://gvisor/.../nightly/2026-05-19/x86_64/runsc` | identical ✅ |
| pauseImage | `gke-release/pause@sha256:bcbd57…` | identical ✅ |
| workerPoolRef | `kagent-default` | `kagent-default` ✅ |
| ate-api secret RBAC | chart installs Role/RoleBinding | `kagent-ate-api-env-sources` present ✅ |

Take-aways from the README that match our findings:
- The **"OpenClaw gateway" is not a Gateway-API Gateway.** It is the `openclaw gateway run --port 80
  --allow-unconfigured` process **inside the actor sandbox**. kagent proxies UI traffic to it through
  Substrate's **atenet-router (Envoy)** using the actor `Host` header
  (`<actor-id>.actors.resources.substrate.ate.dev`).
- The **gateway token** is a self-issued bearer string supplied per-harness via `gatewayToken` or
  `gatewayTokenSecretRef` (Secret key must be `token`). Nothing generates it for you.
- `snapshotsConfig.location` defaults to `gs://ate-snapshots/<ns>/<name>`. The `gs://` scheme is
  canonical; our rustfs store backs it (golden snapshots land successfully).

**Conclusion: there is nothing left to fix in the manifest/config layer. We run the documented
configuration exactly.**

---

## 2. What actually happens here (the blocker)

The harness walks the entire chain and dies only at actor restore:

```
CreateActor (golden) → ResumeActor → STATUS_RUNNING            ✅
CheckpointWorkload → golden snapshot stored in rustfs          ✅   ActorTemplateReady=True
CreateActor ahr-kagent-<harness> (logical actor)              ✅
ResumeActor ahr-kagent-<harness>
   ❌ workflow failed at step CallAteletRestore:
      while creating workload from golden snapshot:
      rpc error: code = DeadlineExceeded desc = context deadline exceeded   (~28s)
```

Harness condition: `ActorReady=False (ActorResuming) "actor is resuming"` — never completes, retries forever.

### Proof it is node.js-specific, not our environment or our config
On this **same cluster, same workers, same `systrap` platform**, Go actors checkpoint **and restore**
fine — repeatedly and live:
- `ui-substrate-agent` (Go runtime) restored at `18:53`, `19:48`, `19:49` — every `RestoreWorkload`
  returned `err:null` in 0.5–2.2s.
- The node.js `openclaw` actor never produces a successful `runsc restore` of its app container; the
  resume RPC just times out.

So the boundary is **(node.js/V8 workload) × (gVisor C/R)** — Go is unaffected here.

### New data point vs the original proposal (diagnosed 2026-06-16)
The failure surfaces as **different errors at different layers, depending on which deadline trips first** —
but it is the **same gVisor restore failure**, confirmed by drilling into the RPC layers:

- **ate-api** (`ResumeActor`) gives up at its ~28s deadline → `CallAteletRestore … DeadlineExceeded`.
- **atelet** (`AteomHerder/Restore`) has no such short deadline, so it shows the real outcome:
  `while calling ateom.RestoreWorkload: rpc error: code = Internal desc = internal server error`, with
  elapsed times ranging **16s to ~3m51s** across retries.

That elapsed-time spread is the key fact: `ateom` genuinely **runs `runsc restore` of the node container
for up to ~4 minutes and then fails internally** — this is *not* a fixed-timeout problem and *not* a
pre-gVisor snapshot-staging stall. The restore actually executes and fails. The Go actor restores in
~2s on the same worker/platform. So this is the documented gVisor multi-container C/R failure of the
node.js/V8 workload; only the *surfaced* error string changed between 0.9.7 and 0.9.8.

**Consequence:** raising the restore deadline cannot help — ateom already runs for minutes and still
fails. The fix must change C/R fidelity (runsc version or gVisor platform), not the timeout.

Note: an earlier custom-image experiment (`matcham89/nemoclaw-sandbox-base:tmpdirs-20260615`, ActorTemplate
`nemoclaw-sandbox`) hit the **same** ateom `Internal server error` on restore — so image-level tmpdir
tweaks did not move it either.

---

## 3. Levers we checked — and which exist

| Lever | Available? | Notes |
|---|---|---|
| `resumePolicy: diskOnly` / cold-start | ❌ | Not in the `0.9.8` `AgentHarness` CRD. Proposal Option D is unimplemented. |
| Restore/resume timeout knob | ❌ | Not on `AgentHarness`/`ActorTemplate`/`WorkerPool` CRDs, not in `ate-api-server` args. The ~28s deadline is internal. |
| gVisor `kvm` platform | ❌ (not ready) | No `/dev/kvm` device plugin on any node (`devices.kubevirt.io/kvm` empty on control-01..03, worker-01..03). Would need hardware-virt confirmation + a KVM device plugin + an ateom-gvisor that selects `--platform=kvm`. |
| runsc version | ⚠️ config-only | `controller.substrate.runscAMD64URL/SHA256` (+arm64) overridable in the kagent operator HelmRelease. Currently unset → chart default `2026-05-19`. Newer `2026-06-13` previously broke checkpoint outright. |
| Custom ateom-gvisor build | ⚠️ we have the pipeline | We already build `matcham89/atecontroller:0.0.6-shmfix` via `ko` + a Flux postRenderer, so patching ateom (deadline, platform, flags) is feasible. |

---

## 4. Get-it-running-now plan (substrate + AgentHarness, Talos homelab)

Ordered by effort/payoff. (1) keeps everything config-only; (2)–(3) are deeper but still keep substrate.

### Experiment 0 — rebuild ateom-gvisor + substrate from repo HEAD on Talos (do FIRST, highest leverage)
The Kind E2E that **works** (§6) ran substrate **repo HEAD** (18 commits past `v0.0.6`, incl.
`ef1c9ed Fix gvisor cleanup issue`, `b923428 Fix ateom cleanup failure handling`). Talos runs the
released `ateom-gvisor:v0.0.6`. Eliminate that variable:
1. `KO_DOCKER_REPO=<your repo> KO_DEFAULTPLATFORMS=linux/amd64 ko build -B ./cmd/ateom-gvisor` from the
   substrate repo HEAD (we already have the `ko` pipeline + a custom-image postRenderer).
2. Point the WorkerPool `substrateWorkerPool.ateomImage` at the HEAD build; bump the substrate chart/
   images similarly.
3. Recreate the harness, watch the resume.
- If it **works** → the fix is simply "move past `v0.0.6`," and we're done.
- If it **still fails** → the cause is **amd64 vs arm64** or **host kernel**, not the code (see below).
This is the single experiment that most cleanly separates "stale release" from "amd64/kernel".

### Experiment 1 — runsc version sweep (if Exp 0 doesn't fix it)
Candidate gVisor nightlies confirmed available (hashes computable via
`curl -sL https://storage.googleapis.com/gvisor/releases/nightly/<DATE>/x86_64/runsc | shasum -a256`):
`2026-05-26, 2026-06-02, 2026-06-05, 2026-06-09, 2026-06-11, 2026-06-12` (all HTTP 200), window bounded
by `2026-05-19` (checkpoint OK) and `2026-06-13` (checkpoint broke). Method validated: 2026-05-19 hashes
to the known `a397be1…842b63`.
The blocker is C/R fidelity, so try other gVisor nightlies and find one where **both** checkpoint and
restore of the node actor succeed.

- Add to the kagent operator HelmRelease under `controller.substrate`:
  ```yaml
  runscAMD64URL: gs://gvisor/releases/nightly/<DATE>/x86_64/runsc
  runscAMD64SHA256: <sha>
  runscARM64URL: gs://gvisor/releases/nightly/<DATE>/aarch64/runsc
  runscARM64SHA256: <sha>
  ```
- Per candidate: reconcile → recreate the harness → watch `ResumeActor` and the worker `runsc restore`.
- Sweep window: between `2026-05-19` (checkpoint works) and `2026-06-13` (checkpoint broke), plus a few
  newer ones in case the node-restore path was fixed later.
- **Caveat:** the proposal root-caused this as a structural multi-container MF-ownership issue, so a
  version bump may not fix it — but it is the only cheap lever and worth a handful of tries on a homelab.

### Experiment 1b — bump the restore deadline ~~(ruled out 2026-06-16)~~
**DISPROVEN — do not pursue.** Diagnosis showed `ateom.RestoreWorkload` already runs for **16s–3m51s**
and still fails with `Internal server error`. It is a genuine restore *failure*, not "slow-but-would-
succeed," so a longer deadline cannot help. The 28s `DeadlineExceeded` is only ate-api giving up early;
atelet/ateom keep grinding for minutes and fail anyway.

### Experiment 2 — gVisor `kvm` platform (most likely structural fix, higher effort)
gVisor's KVM platform has the most mature C/R; `systrap` (our current software-only platform) is the
weakest path for large JIT/V8 memory.
1. Confirm Talos nodes expose hardware virt / `/dev/kvm` (bare-metal VT-x or nested virt).
2. Deploy a KVM device plugin and expose `/dev/kvm` to the ateom workers.
3. Build/configure ateom-gvisor to run `--platform=kvm`.
Uncertain payoff (KVM C/R of node may also fail) but it is the experiment that most directly targets the
suspected platform sensitivity.

### Fallback — cold-boot OpenClaw outside substrate C/R
If the goal is "OpenClaw running today" rather than "through the substrate AgentHarness," run the
`sandbox-base` image as a plain Deployment, or use the `SandboxAgent` path (`agents.x-k8s.io`, our
`sandbox-agent` already works) — no gVisor checkpoint/restore involved. This abandons substrate's
snapshot/resume model, so it does **not** validate substrate + AgentHarness.

---

## 5. Operational notes / gotchas

- The harness retries the resume forever (status flaps `1`↔`4`). Stop the churn while iterating:
  `kubectl delete agentharness <name> -n kagent`.
- Use `gatewayTokenSecretRef: {name: harness-gateway-token}` (key `token`, synced from Bitwarden via
  ESO) rather than an inline `gatewayToken` for real runs.
- See also: `2026-06-15-substrate-kagent-talos-deployment-writeup.md` (full saga incl. the
  `user.max_user_namespaces=65536` Talos sysctl, JWT issuer, valkey fragility) and
  `PROPOSAL-kagent-substrate-openclaw-checkpoint-restore.md` (upstream bug proposal).

---

## 6. Kind E2E comparison (2026-06-16) — OpenClaw restore SUCCEEDS on Kind

Full local reproduction on Apple Silicon (Docker Desktop) following the upstream README, to compare
against the failing Talos run.

**Setup:** `kagent-dev/substrate` repo HEAD + `kagent` repo built from source via `make helm-install`;
`hack/create-kind-cluster.sh` + `hack/install-ate-kind.sh --deploy-ate-system`; `ateom-gvisor`,
control plane, and kagent all built locally for `linux/arm64` and pushed to `localhost:5001`.

**Result:** the `openclaw-kind` AgentHarness (`runtime: substrate`, `backend: openclaw`,
`modelConfigRef: default-model-config`, `gatewayToken: test-token`) went green in ~45s:
```
ActorTemplateReady=True  →  ActorReady=True (ActorRunning, 10.244.0.37)  →  BootstrapReady=True
worker: "About to run runsc restore" container=openclaw  →  "Actor restored"
        RestoreWorkload err:null  elapsed-time: 948.8ms     Platform: systrap
```
The **node.js OpenClaw actor checkpointed and restored** — the precise step that fails on Talos.

### Variable-by-variable comparison

| Factor | Kind (✅ restores) | Talos (❌ fails) | Controlled? |
|---|---|---|---|
| OpenClaw image | `sandbox-base@sha256:d52bee…` (arm64) | same digest (amd64) | digest same, **arch differs** |
| runsc nightly | `2026-05-19` (aarch64) | `2026-05-19` (x86_64) | date same, **arch differs** |
| gVisor platform | **`systrap`** | **`systrap`** | ✅ SAME — KVM theory dead |
| `/dev/kvm` | absent | absent | ✅ SAME |
| Snapshot store | rustfs + valkey | rustfs + valkey | ✅ SAME |
| kagent flow | AgentHarness→ActorTemplate→resume | same | ✅ SAME |
| **ateom / substrate code** | **repo HEAD (+18 past v0.0.6)** | **released `v0.0.6`** | ❌ **DIFFERS** |
| **CPU arch** | **arm64** | **amd64** | ❌ **DIFFERS** |
| **Host kernel** | **6.6.119-0-virt** (Docker Desktop VM) | Talos kernel, bare metal | ❌ **DIFFERS** |

### What this proves / kills
- **KILLED:** "gVisor can't C/R node.js/V8" (it just did, in 948ms). "It's the platform / need KVM"
  (both are `systrap`, neither has `/dev/kvm`). "It's the snapshot store / multi-container model"
  (identical rustfs + same pause+app model, works on Kind).
- **REMAINING suspects (ranked) — UPDATED after Experiment 0 (§7):**
  1. ~~**ateom code version**~~ — **ELIMINATED.** Built ateom-gvisor from HEAD (`6d7b14d`) for amd64,
     deployed on Talos → restore **still fails** with the identical `inconsistent private memory files`.
     Same code as the working Kind run; only the arch differs. So it is NOT the substrate version.
  2. **CPU arch (amd64) — now the prime suspect.** gVisor `systrap` C/R of the node.js/V8 private
     memory works on **arm64** (Kind) and fails on **amd64** (Talos) with the MF-ownership error, with
     byte-identical ateom code + same runsc nightly. Strongly points to an amd64-specific gVisor C/R bug.
  3. **Host kernel** — Talos kernel vs Docker Desktop `6.6.119-virt` (cannot be separated from arch
     without an amd64 host running a different kernel, or arm64 Talos nodes — neither available here).

### Sharper framing for the upstream proposal
Not "node C/R is broken" but: **OpenClaw node.js checkpoint/restore works under gVisor `systrap` on
arm64 (Kind, repo HEAD) and fails under `systrap` on amd64 (Talos, `v0.0.6`).** The decisive questions
for maintainers: (a) is there a node-relevant C/R fix between `v0.0.6` and HEAD? (b) is the
`inconsistent private memory files` restore failure amd64-specific?

### Kind cluster left running
`kind-kind` context, cluster `kind`, registry `localhost:5001`. Tear down with
`cd ~/Documents/github/substrate && ./hack/delete-kind-cluster.sh` (+ `docker rm -f kind-registry`).

---

## 7. Experiment 0 result — HEAD ateom on Talos amd64 STILL FAILS (2026-06-16)

Built `ateom-gvisor` from substrate HEAD (`6d7b14d`) for **linux/amd64**, pushed to
`docker.io/matcham89/ateom-gvisor:head-6d7b14d`, patched the Talos WorkerPool
`spec.ateomImage` to it (ate-controller redeployed the workers; confirmed image + `runsc` version
`release-20260511.0-42-ga7924c4ef10d`, `amd64`). Deployed a fresh `openclaw-head` AgentHarness
(`gatewayTokenSecretRef: harness-gateway-token`).

**Result: golden snapshot OK → resume FAILS, identical error to `v0.0.6`:**
```
RestoreWorkload openclaw-head: while running `runsc restore`: exit status 128
FATAL ERROR: starting sub-container [... openclaw gateway run --port 80 --allow-unconfigured]:
  inconsistent private memory files on restore:
    savedMFOwners = [pause:/], mfmap = map[openclaw:/:unwasteSmall: ...]
```
(Valkey was healthy; a couple of transient `CLUSTERDOWN` lock errors during the test were noise, not
the cause — the real failure is the `runsc restore` MF inconsistency.)

**Conclusion — the comparison is now fully controlled and the cause is isolated:**

| Variable | Kind (✅) | Talos (❌) | Status |
|---|---|---|---|
| ateom code | HEAD `6d7b14d` | **HEAD `6d7b14d`** | now IDENTICAL |
| runsc nightly | `2026-05-19` (release-20260511.0-42) | same build | identical (diff arch binary) |
| openclaw image / platform / store | d52bee / systrap / rustfs | same | identical |
| **CPU arch** | **arm64** | **amd64** | **the remaining differentiator** |

→ **It is not the substrate version. The OpenClaw node.js checkpoint/restore is broken on amd64 gVisor
`systrap` and works on arm64**, all else equal. Pinning Talos to HEAD substrate will not fix this.

### What now (get-it-running options, post-isolation)
1. **runsc nightly sweep on amd64 (only remaining config lever).** The bug lives in amd64 `runsc
   restore` MF accounting; a different amd64 nightly may fix it. Window: after `2026-05-19`, mind that
   `2026-06-13` broke checkpoint. Candidates already confirmed present (§4 Exp 1). Override
   `controller.substrate.runscAMD64URL/SHA256` in the kagent operator HelmRelease.
2. **Report upstream with the crisp repro** (this is the highest-value action): *same ateom HEAD + same
   runsc 2026-05-19 + same openclaw image — restores on arm64 `systrap`, fails on amd64 `systrap` with
   `inconsistent private memory files`.* That bounds the bug to amd64 for the gVisor/substrate maintainers.
3. **Run OpenClaw without substrate C/R** (SandboxAgent / plain Deployment) if you just need it running
   on amd64 today.
4. **Arm64 substrate workers** would work (proven on Kind) — but there are no arm64 Talos nodes.

### Talos cluster state after this experiment
WorkerPool `kagent-default` reverted to GitOps `ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.6`
(HEAD ateom did not help — the cause is arch, not version).

---

## 8. RESOLUTION — runsc amd64 sweep found the fix (2026-06-16)

Swept amd64 runsc nightlies via `kubectl set env deploy/kagent-controller SUBSTRATE_RUNSC_AMD64_URL/SHA256`
(restart controller → fresh harness → observe), WorkerPool on `v0.0.6` ateom:

| runsc nightly (amd64) | checkpoint | restore | verdict |
|---|---|---|---|
| `2026-05-19` (default) | ✅ | ❌ `inconsistent private memory files` | fails |
| `2026-05-26` | ✅ | ❌ `inconsistent private memory files` | fails |
| **`2026-06-02`** | **✅** | **✅** | **SUCCESS — `Ready=True / ActorRunning`** |
| `2026-06-13` (per writeup) | ❌ broke checkpoint | — | unusable |

So the gVisor amd64 C/R fix landed in `(2026-05-26, 2026-06-02]`, and `06-02` is before the `06-13`
checkpoint regression — a working window. **Confirmed clean run:** `openclaw-final` golden snapshot →
resume → `Ready=True` in ~104s.

### The fix (staged in GitOps — commit to make permanent)
`flux/apps/base/kagent/operator/helmrelease.yaml`, under `controller.substrate`:
```yaml
runscAMD64URL: "gs://gvisor/releases/nightly/2026-06-02/x86_64/runsc"
runscAMD64SHA256: "efd12935f6654c91a1389710eb8dfa4d12b6b9be00db87526dc2eb584ad00119"
```
(arm64 left on chart default — no arm64 Talos nodes; arm64 already restores at `05-19`.) Until committed,
the running controller carries the same value via a live `kubectl set env` patch (persists — drift
detection is off). Committing makes Flux render it from the chart value; identical result.

### Operational caveat learned the hard way
Rapid harness create/**force-delete** cycling (clearing the `agent-harness-backend-cleanup` finalizer)
**leaks `actor:*` / `worker:*` keys in valkey** → `no free workers available` and stuck golden snapshots.
Recovery used: delete the leaked keys across valkey nodes
(`redis-cli -c DEL actor:ahr-kagent-<name>` + the `worker:kagent:kagent-default:*` assignment keys) and
`kubectl rollout restart deploy/kagent-default-deployment`. Prefer graceful harness deletion (let the
finalizer run) over force-clearing when iterating.
