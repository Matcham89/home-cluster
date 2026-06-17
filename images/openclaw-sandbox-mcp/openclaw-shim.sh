#!/bin/sh
# openclaw shim — injects the kagent agent broker as an MCP server into the gateway
# config at startup, then hands off to the real OpenClaw gateway.
#
# Installed as /usr/local/bin/openclaw in a derivative of
# ghcr.io/kagent-dev/nemoclaw/sandbox-base. The kagent-generated actor startup
# command runs `openclaw gateway run --port 80 --allow-unconfigured` after writing
# ~/.openclaw/openclaw.json; this shim intercepts that bare `openclaw` call, merges
# the MCP config, and execs the real gateway. Runs on every boot -> snapshot-safe.
#
# Merge failures are non-fatal: we log and still start the gateway so a config quirk
# can never break the dashboard.
CONFIG="${HOME:-/root}/.openclaw/openclaw.json"
if [ -f "$CONFIG" ]; then
  python3 /usr/local/bin/openclaw-mcp-merge.py "$CONFIG" \
    || echo "openclaw-shim: MCP merge skipped (merge error, continuing)" >&2
fi
exec node /usr/local/lib/node_modules/openclaw/openclaw.mjs "$@"
