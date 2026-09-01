# OpenClaw on Substrate (Talos) — status & deferred follow-ups

**Last updated:** 2026-06-16 · **Owner:** matcham89

Quick "where things stand + what to resume another day" companion to
`substrate-openclaw-talos.md` (full investigation), `PROPOSAL-kagent-substrate-openclaw-checkpoint-restore.md`
(upstream bug report), and `2026-06-15-substrate-kagent-talos-deployment-writeup.md` (the saga).

---

## ✅ Resolved (the main thing)

OpenClaw (`backend: openclaw`, substrate runtime) now **checkpoints and restores** on the amd64 Talos
cluster and serves its dashboard.

- **Root cause:** an amd64-specific gVisor checkpoint/restore bug in the kagent-default runsc nightly
  `2026-05-19` (`inconsistent private memory files on restore`). Fixed by gVisor in `2026-06-02`.
- **Fix (committed):** `flux/apps/base/kagent/operator/helmrelease.yaml` →
  `controller.substrate.runscAMD64URL/SHA256 = 2026-06-02` (commit `5a21f714`). arm64 left on default.
- **Upstream:** PR https://github.com/kagent-dev/kagent/pull/2035 (bump amd64 default) + issue
  https://github.com/kagent-dev/kagent/issues/2036.
- **Verified:** `openclaw-final` harness → `Ready / ActorRunning`; dashboard reachable **via port-forward
  AND over the public ingress** (`https://kagent.kubegit.com/api/agentharnesses/kagent/openclaw-final/gateway/`)
  and answering chat (with a real OpenAI key).

### Dashboard over the ingress (`kagent.kubegit.com`) — RESOLVED 2026-06-17 (was a misdiagnosis)
The earlier "the WS upgrade is silently dropped over the ingress" item was **never a server-side problem**.
The full chain forwards WebSockets correctly end-to-end:
`cloudflared → ingress-gateway (agentgateway 0.11.1) → HTTPRoute kagent-route → oauth2-proxy → kagent-ui →
controller`. Verified hop-by-hop: each returns `101 Switching Protocols` + `connect.challenge`, and oauth2-proxy
proxies the **authenticated** WS fine (it logs the hijacked upgrade as status `0`; `--proxy-websockets`
defaults `true`). No config change was needed — agentgateway/oauth2-proxy/Cloudflare were left untouched.

**Two false signals had pointed at a phantom "drop":**
1. **Stale socket URL saved in the browser.** The OpenClaw Control UI persists its gateway URL in
   *per-browser* `localStorage`. From port-forward days it held `ws://localhost:8001/...`. Over the `https://`
   ingress that's **insecure mixed content** → the browser (Safari, strictly) blocks it *before any request
   leaves the browser* (so nothing reaches oauth2-proxy — the server logs stay empty). Chrome worked because
   its `localStorage` had no stale URL and defaulted to same-origin `wss://kagent.kubegit.com/...`.
   **Fix:** clear the saved URL (OpenClaw UI connection setting → blank/`wss://kagent.kubegit.com/.../gateway/`,
   or clear Safari website data for `kubegit`). Rule: over the ingress the socket must be
   `wss://kagent.kubegit.com/...`, never `ws://localhost:...`.
2. **HTTP/2 probe artifact.** WebSocket upgrades use the HTTP/1.1 `Upgrade`/`Connection` mechanism, which
   **does not exist in HTTP/2**. Any curl/probe that negotiated h2 with Cloudflare had its `Upgrade: websocket`
   header ignored and got back plain `200`/HTML — looking exactly like a drop. Always probe WS with
   `curl --http1.1`.

**Gateway topology (confirmed):** `agentgateway` is the *data-plane proxy* (GatewayClass `agentgateway`,
controller `agentgateway.dev/agentgateway`, the `ingress/ingress-gateway` pod on `192.168.1.201`). **kgateway**
`v2.2.0` is the *controller* that programs it (`managed-by: kgateway` on the Deployment). The OpenClaw path uses
the single `ingress/ingress-gateway` Gateway — unchanged.

---

## 🔜 Deferred — resolve another day

### 2. Track upstream; drop the pin when fixed
**Problem:** `2026-06-02` is a hand-pinned gVisor nightly — a workaround for a fast-moving dependency.

**Callback:**
- Watch PR #2035 / issue #2036. If maintainers bump the kagent default (and substrate blesses a runsc),
  **remove our override** and fall back to the chart default.
- Consider switching the Flux substrate `OCIRepository` from `tag: "0.0.6"` to `semver: ">=0.0.6"` to
  auto-track future *released* substrate versions (separate decision — adds auto-update risk).

### 3. Confirm arch vs kernel (low priority / for the upstream report)
**Problem:** we proved arm64-restores / amd64-fails with the same code+runsc, but the arm64 box ran a
different host kernel (Docker Desktop VM), so "purely amd64" isn't 100% proven.

**Callback:** if it ever matters, test amd64 on a non-Talos kernel, or arm64 on Talos. Not needed for the
fix (already working); only sharpens the upstream root-cause story.

### 4. Valkey fragility / leaked-actor hygiene (operational)
**Problem:** force-deleting harnesses (clearing the `agent-harness-backend-cleanup` finalizer) leaks
`actor:*`/`worker:*` keys in valkey → `no free workers`. Also valkey cluster has no stable addressing
(recurs on pod IP changes — see the writeup §2).

**Callback:** prefer graceful harness deletion. Recovery runbook (leaked workers): DEL the leaked
`actor:ahr-kagent-<name>` + `worker:kagent:kagent-default:<pod>` keys across all `valkey-cluster-N`, then
`kubectl rollout restart deploy/kagent-default-deployment`. A chart-level stable-addressing fix for valkey
is still wanted upstream.

### 5. Housekeeping
- **Kind comparison cluster** still running locally: `~/Documents/github/substrate/hack/delete-kind-cluster.sh`
  + `docker rm -f kind-registry` to tear down.
- **Docker Hub `matcham89/ateom-gvisor`** has experiment tags (`head-6d7b14d`, `0.0.6-*`) — prune when done.
- **Untracked docs** in `docs/` (this file, the writeup, the proposal) — commit when ready.
- Default kubectl context is `kind-kind`; consider `kubectl config use-context admin@talos-homelab`.
