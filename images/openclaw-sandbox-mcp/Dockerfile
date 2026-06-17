# Derivative of the kagent/nemoclaw OpenClaw sandbox base that bridges the kagent
# agent broker (controller /mcp) into the gateway config at startup. Snapshot-safe:
# the MCP config is re-applied on every boot before `openclaw gateway run`, so the
# golden snapshot captures it.
#
# Base pinned by digest to match the kagent v0.9.8 ActorTemplate default. Build amd64
# (the Talos cluster is amd64):
#   docker buildx build --platform linux/amd64 \
#     -t docker.io/matcham89/openclaw-sandbox-mcp:0.1.0 --push images/openclaw-sandbox-mcp/
FROM ghcr.io/kagent-dev/nemoclaw/sandbox-base@sha256:d52bee415dc4c0dba7164f9eabe727574c056d4f211781f20af249707883a3b4

# Shim the `openclaw` launcher (a symlink to openclaw.mjs) with our wrapper, which
# merges MCP config then execs `node .../openclaw.mjs`.
COPY openclaw-mcp-merge.py /usr/local/bin/openclaw-mcp-merge.py
COPY openclaw-shim.sh      /usr/local/bin/openclaw
RUN chmod 0755 /usr/local/bin/openclaw /usr/local/bin/openclaw-mcp-merge.py
