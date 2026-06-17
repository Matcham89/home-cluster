#!/usr/bin/env python3
"""Inject the kagent agent broker as an MCP server into the OpenClaw gateway config.

The kagent substrate/openclaw backend writes a fixed ~/.openclaw/openclaw.json at
actor boot (with no `mcp` section) and then runs `openclaw gateway run`. This script
is invoked by the `openclaw` shim *before* the real gateway starts, so the MCP server
is present every boot and is captured by the golden snapshot (i.e. survives C/R).

We bridge only the kagent CONTROLLER's aggregated MCP endpoint (the "broker"): it
exposes `list_agents` / `invoke_agent`, so OpenClaw can reach every kagent agent
(k8s, flux, etc.) over A2A through this single endpoint. To wire additional MCP
servers directly later, add entries to SERVERS.
"""
import json
import os
import sys

# --- kagent MCP servers exposed to OpenClaw (edit to add more) ---
SERVERS = {
    # Agent broker: list_agents / invoke_agent -> any kagent agent via A2A.
    # (Egress to this plaintext-HTTP cluster endpoint is verified from the actor.)
    "kagent": {
        "url": "http://kagent-controller.kagent:8083/mcp",
        "transport": "streamable-http",
        "enabled": True,
    },
}

# Tools allowed in sandboxed agent turns so the MCP-sourced tools can actually fire.
ALSO_ALLOW = ["bundle-mcp", "group:plugins"]


def main(path):
    with open(path) as f:
        cfg = json.load(f)

    servers = cfg.setdefault("mcp", {}).setdefault("servers", {})
    for name, spec in SERVERS.items():
        servers[name] = spec

    allow = (
        cfg.setdefault("tools", {})
        .setdefault("sandbox", {})
        .setdefault("tools", {})
        .setdefault("alsoAllow", [])
    )
    for a in ALSO_ALLOW:
        if a not in allow:
            allow.append(a)

    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, path)
    print("openclaw-mcp-merge: injected %d MCP server(s)" % len(SERVERS), file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv[1])
