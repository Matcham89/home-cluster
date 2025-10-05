# KGateway Configuration

## Overview

This directory contains the configuration for **KGateway**, a Kubernetes-native API gateway that provides intelligent routing and protocol translation for various types of services, including AI agents and MCP (Model Context Protocol) servers.

### What is KGateway?

KGateway is a modern API gateway built on the Kubernetes Gateway API standard. It provides:
- **Standard Gateway API compliance** - Uses native Kubernetes Gateway/HTTPRoute resources
- **Agent Gateway capabilities** - Special routing for AI agents and MCP servers
- **Dynamic service discovery** - Automatically discovers and routes to MCP servers via label selectors
- **Protocol translation** - Handles different transport types (HTTP, SSE, stdio)

### What is AgentGateway?

AgentGateway is a specific component within KGateway that provides:
- **MCP Protocol Support** - Native understanding of Model Context Protocol (MCP) for AI agent communication
- **Dynamic MCP Routing** - Automatically discovers MCP servers using Kubernetes labels
- **SSE (Server-Sent Events)** - Handles streaming connections required by MCP
- **Multi-backend aggregation** - Can route to multiple MCP servers simultaneously

## Architecture

```
Client Request (http://192.168.1.53:8080/mcp)
    ↓
[Gateway: agentgateway] (port 8080, LoadBalancer)
    ↓
[HTTPRoute: yt-mcp-route] (matches /mcp)
    ↓
[Backend: yt-mcp-backend] (MCP type, uses label selector)
    ↓
[Service: yt-kmcp-kagent] (label: kagent.dev/mcp-service=true)
    ↓
[Pod: yt-kmcp] (MCP server running on port 3000)
```

## Directory Structure

```
kgateway/
├── README.md                          # This file
├── crds/
│   ├── helmrelease.yaml              # Installs KGateway CRDs
│   └── kustomization.yaml
├── operator/
│   ├── helmrelease.yaml              # Installs KGateway controller & agentgateway
│   └── kustomization.yaml
└── operations/
    ├── gateway.yaml                  # Gateway resource (entrypoint)
    ├── backends.yaml                 # Backend definitions (MCP routing logic)
    ├── httproute.yaml                # HTTPRoute definitions (path matching)
    ├── a2a.yaml                      # Agent-to-Agent example deployment
    └── kustomization.yaml
```

## Components Explained

### 1. Gateway Resource (`gateway.yaml`)

The **Gateway** is the entry point for all traffic. Think of it as the front door.

```yaml
kind: Gateway
metadata:
  name: agentgateway
spec:
  gatewayClassName: agentgateway
  listeners:
    - protocol: HTTP
      port: 8080
      name: http
```

- **What it does**: Listens on port 8080 for incoming HTTP requests
- **Service**: Exposed via LoadBalancer at `192.168.1.53:8080`
- **Gateway Class**: Uses `agentgateway` class which enables MCP support

### 2. HTTPRoute Resources (`httproute.yaml`)

**HTTPRoutes** define path-based routing rules. They connect URLs to backends.

#### MCP Route
```yaml
kind: HTTPRoute
metadata:
  name: yt-mcp-route
spec:
  parentRefs:
    - name: agentgateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      backendRefs:
        - name: yt-mcp-backend
          kind: Backend
```

- **What it does**: Routes requests to `/mcp` to the YouTube MCP backend
- **Example**: `http://192.168.1.53:8080/mcp` → `yt-mcp-backend`

#### Agent-to-Agent Route
```yaml
kind: HTTPRoute
metadata:
  name: a2a
spec:
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /a2a
      backendRefs:
        - name: a2a-agent
          port: 9090
```

- **What it does**: Routes requests to `/a2a` to the agent-to-agent test service
- **Example**: `http://192.168.1.53:8080/a2a` → `a2a-agent:9090`

### 3. Backend Resources (`backends.yaml`)

**Backends** define the routing logic for finding and connecting to services. This is where KGateway's intelligence lives.

```yaml
apiVersion: gateway.kgateway.dev/v1alpha1
kind: Backend
metadata:
  name: yt-mcp-backend
spec:
  type: MCP
  mcp:
    targets:
      - name: yt-kmcp-kagent
        selector:
          service:
            matchLabels:
              kagent.dev/mcp-service: "true"
```

- **Type: MCP**: Tells KGateway this is an MCP server (requires SSE support)
- **Label Selector**: Automatically finds services with `kagent.dev/mcp-service: "true"`
- **Dynamic Discovery**: If you deploy more MCP servers with this label, they're auto-discovered

#### How MCP Discovery Works

1. Backend looks for services with label `kagent.dev/mcp-service: "true"`
2. Finds service `yt-kmcp-kagent` with annotations:
   - `kagent.dev/mcp-service-path: /mcp` (optional path override)
   - `appProtocol: kgateway.dev/mcp` (required protocol marker)
3. Routes traffic to that service

### 4. MCP Service Requirements

For a service to be discovered by the MCP backend, it must have:

```yaml
apiVersion: v1
kind: Service
metadata:
  labels:
    kagent.dev/mcp-service: "true"  # Discovery label
  annotations:
    kagent.dev/mcp-service-path: /mcp  # Optional: MCP endpoint path
    kagent.dev/mcp-service-port: "3000"  # Optional: port override
spec:
  ports:
    - appProtocol: kgateway.dev/mcp  # REQUIRED: marks this as MCP
      port: 3000
```

## Current Deployments

### 1. YouTube MCP Server (`yt-kmcp`)

- **Purpose**: MCP server providing YouTube data tools
- **Access**: `http://192.168.1.53:8080/mcp`
- **Service**: `yt-kmcp-kagent` (port 3000)
- **Labels**: `kagent.dev/mcp-service=true`
- **Transport**: Streamable HTTP (SSE)

### 2. Agent-to-Agent Test (`a2a-agent`)

- **Purpose**: Test service for agent-to-agent communication
- **Access**: `http://192.168.1.53:8080/a2a`
- **Service**: `a2a-agent` (port 9090)
- **Image**: `gcr.io/solo-public/docs/test-a2a-agent:latest`

## Testing Your MCP Connection

### Using MCP Inspector (Recommended)

The MCP Inspector is the official tool for testing MCP servers:

```bash
# Install and run MCP Inspector
npx @modelcontextprotocol/inspector@0.16.2
```

Configuration:
- **Transport Type**: Streamable HTTP
- **URL**: `http://192.168.1.53:8080/mcp` (or `http://localhost:8080/mcp` with port-forward)

### Using Port-Forward (Optional)

If you want to test via localhost:

```bash
# Port-forward to agentgateway service
kubectl port-forward -n apps svc/agentgateway 8080:8080

# Then use in MCP Inspector
# URL: http://localhost:8080/mcp
```

### Why curl Doesn't Work

```bash
curl http://192.168.1.53:8080/mcp
# Returns: 406 Not Acceptable: Client must accept text/event-stream
```

This is **expected behavior**! MCP requires:
- `Accept: text/event-stream` header (for SSE streaming)
- `Accept: application/json` header (for JSON-RPC responses)
- Proper JSON-RPC message format

Regular curl doesn't support the SSE protocol properly, so use MCP Inspector instead.

## How to Add a New MCP Server

1. **Deploy your MCP server** (as a Deployment + Service)

2. **Label your service** for auto-discovery:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-mcp-server
  labels:
    kagent.dev/mcp-service: "true"  # Required for discovery
  annotations:
    kagent.dev/mcp-service-path: /mcp  # Optional
spec:
  ports:
    - name: mcp
      port: 3000
      appProtocol: kgateway.dev/mcp  # Required
```

3. **Create an HTTPRoute** (if you want a dedicated path):
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-mcp-route
spec:
  parentRefs:
    - name: agentgateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /my-mcp
      backendRefs:
        - name: yt-mcp-backend  # Reuse existing backend
          kind: Backend
          group: gateway.kgateway.dev
```

4. **Access your server**:
   - URL: `http://192.168.1.53:8080/my-mcp`

## Troubleshooting

### Issue: "Backend service unavailable"

**Cause**: HTTPRoute is routing to wrong backend or service doesn't exist

**Check**:
```bash
# Verify service exists
kubectl get svc -n apps

# Check HTTPRoute status
kubectl describe httproute <route-name> -n apps

# Look for ResolvedRefs condition
```

### Issue: "406 Not Acceptable"

**Cause**: Client doesn't support SSE (this is normal for curl)

**Solution**: Use MCP Inspector or another MCP-compatible client

### Issue: Route conflicts (wrong backend serving requests)

**Cause**: HTTPRoute path prefixes overlapping

**Solution**: Ensure routes have specific, non-overlapping paths:
- ✅ Good: `/mcp`, `/a2a`, `/my-service`
- ❌ Bad: `/`, `/m`, `/a` (too broad, will catch other routes)

### Check Gateway Status

```bash
# View Gateway
kubectl get gateway agentgateway -n apps

# Check HTTPRoutes
kubectl get httproute -n apps

# Check Backends
kubectl get backend -n apps

# View agentgateway logs
kubectl logs -n apps -l app.kubernetes.io/name=agentgateway --tail=50
```

### Verify MCP Service Discovery

```bash
# List all services with MCP label
kubectl get svc -n apps -l kagent.dev/mcp-service=true

# Check service details
kubectl get svc yt-kmcp-kagent -n apps -o yaml
```

## Key Concepts to Remember

1. **Gateway** = Entry point (LoadBalancer listening on port 8080)
2. **HTTPRoute** = Path-based routing rules (maps URLs to backends)
3. **Backend** = Routing logic (label selectors, protocol handling)
4. **Service** = Actual target (must have correct labels/annotations for MCP)

5. **Flow**: `Client → Gateway → HTTPRoute → Backend → Service → Pod`

6. **MCP requires**:
   - Label: `kagent.dev/mcp-service=true`
   - AppProtocol: `kgateway.dev/mcp`
   - SSE-compatible client

## Additional Resources

- **KGateway Docs**: https://kgateway.dev/docs/
- **MCP Dynamic Routing**: https://kgateway.dev/docs/main/agentgateway/mcp/dynamic-mcp/
- **Gateway API**: https://gateway-api.sigs.k8s.io/
- **MCP Inspector**: https://github.com/modelcontextprotocol/inspector
