# openclaw-sandbox-mcp

Derivative of the kagent/nemoclaw OpenClaw sandbox base that bridges the **kagent agent
broker** into OpenClaw as an MCP server, so the OpenClaw harness can `list_agents` /
`invoke_agent` (reach every kagent agent over A2A) through one endpoint.

## Why a custom image
The kagent `AgentHarness` (substrate/openclaw) CRD has no field to add MCP servers, the
backend writes a fixed `~/.openclaw/openclaw.json` (no `mcp` section) at boot, and the
live config-patch API protects `mcp.*`. The only durable, snapshot-safe lever is
`spec.substrate.workloadImage` + a startup-time config merge — which this image does via
an `openclaw` shim.

## Contents
- `openclaw-shim.sh` → installed as `/usr/local/bin/openclaw`; merges MCP config then
  execs the real `node .../openclaw.mjs`.
- `openclaw-mcp-merge.py` → injects `mcp.servers.kagent` (controller `/mcp`) and a
  sandbox `alsoAllow` entry. Edit `SERVERS` to bridge more MCP endpoints.

## Build (amd64 — the Talos cluster is amd64)
```sh
docker buildx build --platform linux/amd64 \
  -t docker.io/matcham89/openclaw-sandbox-mcp:0.1.0 --push images/openclaw-sandbox-mcp/
```

## Wire into the harness
Set on the `openclaw` AgentHarness (`flux/apps/base/kagent/agent-harness/openclaw.yaml`):
```yaml
spec:
  substrate:
    workloadImage: docker.io/matcham89/openclaw-sandbox-mcp:0.1.0   # pin by @sha256 once pushed
```
Commit/push, reconcile, and the harness rebuilds its golden snapshot with the broker
MCP server configured.
