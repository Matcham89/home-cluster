# Claude Multi-Gateway Architecture

## Overview

This directory contains the configuration for a **multi-gateway architecture** that provides OpenAI-compatible access to Claude models through dedicated gateways. Each Claude model (Sonnet, Opus, Haiku) has its own gateway, backend, and HTTP route.

**Key Innovation:** No nginx deployment needed! Model selection is enforced at the gateway level through hardcoded backends.

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         WAVE TERMINAL / CLIENT                      │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
                    ▼               ▼               ▼
┌─────────────────────────┐ ┌─────────────────────┐ ┌─────────────────────┐
│ Claude Sonnet Gateway   │ │ Claude Opus Gateway │ │ Claude Haiku Gateway│
│ 192.168.1.206:8091      │ │ 192.168.1.210:8092  │ │ 192.168.1.211:8093  │
└─────────────────────────┘ └─────────────────────┘ └─────────────────────┘
                    │               │               │
                    ▼               ▼               ▼
┌─────────────────────────┐ ┌─────────────────────┐ ┌─────────────────────┐
│  claude-sonnet-route    │ │  claude-opus-route  │ │  claude-haiku-route │
│  /v1/chat/completions   │ │  /v1/chat/completions│ │  /v1/chat/completions│
└─────────────────────────┘ └─────────────────────┘ └─────────────────────┘
                    │               │               │
                    ▼               ▼               ▼
┌─────────────────────────┐ ┌─────────────────────┐ ┌─────────────────────┐
│ claude-sonnet-backend   │ │ claude-opus-backend │ │ claude-haiku-backend│
│ Model: sonnet-4-5       │ │ Model: opus-4-5     │ │ Model: haiku-4-5    │
│ (HARDCODED)             │ │ (HARDCODED)         │ │ (HARDCODED)         │
└─────────────────────────┘ └─────────────────────┘ └─────────────────────┘
                    │               │               │
                    └───────────────┼───────────────┘
                                    ▼
                        ┌───────────────────────┐
                        │   Anthropic API       │
                        │   api.anthropic.com   │
                        └───────────────────────┘
```

## Components

### 1. Gateways (gateway/claude-gateways.yaml)

Three independent Kubernetes Gateway resources:

- **claude-sonnet-gateway** - Port 8091, IP: 192.168.1.206
- **claude-opus-gateway** - Port 8092, IP: 192.168.1.210
- **claude-haiku-gateway** - Port 8093, IP: 192.168.1.211

Each gateway:
- Uses the `agentgateway` GatewayClass
- Has its own LoadBalancer IP address
- Listens on a unique port
- Allows independent policy configuration

### 2. Backends (backends/claude-backends.yaml)

Three AgentgatewayBackend resources that connect to Anthropic's API:

- **claude-sonnet-backend** - Model: `claude-sonnet-4-5` (hardcoded)
- **claude-opus-backend** - Model: `claude-opus-4-5` (hardcoded)
- **claude-haiku-backend** - Model: `claude-haiku-4-5` (hardcoded)

Each backend:
- Specifies the exact Claude model to use
- **Model cannot be overridden by the client**
- Uses credentials from `anthropic-secret`
- Translates between OpenAI-compatible API and Anthropic API

### 3. HTTP Routes (httproute/claude-routes.yaml)

Three HTTPRoute resources that connect gateways to backends:

- **claude-sonnet-route** - Connects sonnet gateway → sonnet backend
- **claude-opus-route** - Connects opus gateway → opus backend
- **claude-haiku-route** - Connects haiku gateway → haiku backend

Each route:
- Matches paths: `/v1/chat/*` and `/v1/completions/*`
- **No hostname matching** - works with IP addresses directly
- Supports OpenAI-compatible API format

## How It Works

### Request Flow

1. **Client Request**: Wave Terminal sends a request to a specific gateway:
   ```
   POST http://192.168.1.206:8091/v1/chat/completions
   ```

2. **Gateway Routing**: The gateway receives the request and routes it via HTTPRoute to the appropriate backend

3. **Backend Processing**: The AgentgatewayBackend:
   - Receives the OpenAI-compatible request
   - **Ignores the model parameter** from the client (if provided)
   - Uses the hardcoded model (`claude-sonnet-4-5`)
   - Translates the request to Anthropic's API format
   - Adds authentication from the secret

4. **Anthropic API Call**: Request is sent to `api.anthropic.com`

5. **Response Translation**: Backend translates the Anthropic response back to OpenAI-compatible format

6. **Client Response**: OpenAI-compatible JSON is returned to the client

### Key Design Decisions

#### Why No /v1/models Endpoint?

Traditional OpenAI-compatible setups require a `/v1/models` endpoint to list available models. This typically requires:
- An nginx deployment serving static JSON
- A ConfigMap with the models list
- A Service to route to nginx

**Our solution eliminates this** because:
- Each gateway has only ONE model (hardcoded in the backend)
- Clients connect directly to the gateway for the model they want
- No model discovery is needed

#### Why Separate Gateways Instead of One Gateway with Multiple Backends?

Using separate gateways provides:

1. **Independent Rate Limiting**: Each model can have different rate limits
2. **Separate Monitoring**: Track usage per model independently
3. **Firewall/Network Policies**: Apply different network rules per model
4. **Resource Isolation**: Scale gateways independently based on load
5. **Cost Tracking**: Monitor API costs per model separately

#### Why Hardcode Models in Backends?

- **Enforcement**: Prevents clients from requesting expensive models through cheap endpoints
- **Simplicity**: No need to validate model names in requests
- **Security**: Ensures billing/quota enforcement at the gateway level
- **Clarity**: Each endpoint has one clear purpose

## Configuration Files

### File Structure

```
kgateway-system/
├── gateway/
│   └── claude-gateways.yaml       # 3 Gateway resources
├── backends/
│   └── claude-backends.yaml       # 3 AgentgatewayBackend resources
├── httproute/
│   └── claude-routes.yaml         # 3 HTTPRoute resources
└── CLAUDE-ARCHITECTURE.md         # This file
```

### Gateway IPs

The LoadBalancer assigns these IPs automatically:

| Gateway                | IP            | Port | Model          |
|------------------------|---------------|------|----------------|
| claude-sonnet-gateway  | 192.168.1.206 | 8091 | Sonnet 4.5     |
| claude-opus-gateway    | 192.168.1.210 | 8092 | Opus 4.5       |
| claude-haiku-gateway   | 192.168.1.211 | 8093 | Haiku 4.5      |

## Client Configuration

### Wave Terminal (waveai.json)

```json
{
  "claude-sonnet-4-5": {
    "display:name": "Claude Sonnet 4.5",
    "display:icon": "sparkles",
    "ai:apitype": "openai-chat",
    "ai:model": "claude-sonnet-4-5",
    "ai:endpoint": "http://claude-sonnet.kubegit.com:8091/v1/chat/completions"
  },
  "claude-opus-4-5": {
    "display:name": "Claude Opus 4.5",
    "display:icon": "crown",
    "ai:apitype": "openai-chat",
    "ai:model": "claude-opus-4-5",
    "ai:endpoint": "http://claude-opus.kubegit.com:8092/v1/chat/completions"
  },
  "claude-haiku-4-5": {
    "display:name": "Claude Haiku 4.5",
    "display:icon": "zap",
    "ai:apitype": "openai-chat",
    "ai:model": "claude-haiku-4-5",
    "ai:endpoint": "http://claude-haiku.kubegit.com:8093/v1/chat/completions"
  }
}
```

### /etc/hosts (Optional)

For friendlier URLs, add to `/etc/hosts`:

```
192.168.1.206 claude-sonnet.kubegit.com
192.168.1.210 claude-opus.kubegit.com
192.168.1.211 claude-haiku.kubegit.com
```

**Note:** This is optional! The gateways work perfectly with IP addresses.

### Direct API Usage

You can also use the gateways directly with curl or any OpenAI-compatible client:

```bash
# Using IP address
curl -X POST http://192.168.1.206:8091/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-5",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'

# Using hostname (requires /etc/hosts entry)
curl -X POST http://claude-sonnet.kubegit.com:8091/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-5",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 100
  }'
```

## Deployment

### Prerequisites

1. **Anthropic API Key**: Stored in `anthropic-secret` secret
2. **AgentGateway**: Installed in the cluster
3. **LoadBalancer**: MetalLB or similar for IP assignment

### Apply Manifests

```bash
# Create all resources
kubectl apply -f gateway/claude-gateways.yaml
kubectl apply -f backends/claude-backends.yaml
kubectl apply -f httproute/claude-routes.yaml

# Verify gateways are ready
kubectl get gateway -n kgateway-system | grep claude

# Check assigned IPs
kubectl get gateway -n kgateway-system claude-sonnet-gateway -o jsonpath='{.status.addresses[0].value}'
kubectl get gateway -n kgateway-system claude-opus-gateway -o jsonpath='{.status.addresses[0].value}'
kubectl get gateway -n kgateway-system claude-haiku-gateway -o jsonpath='{.status.addresses[0].value}'
```

### Verify Routes

```bash
# Check HTTPRoute status
kubectl get httproute -n kgateway-system | grep claude

# Check backend status
kubectl get agentgatewaybackend -n kgateway-system | grep claude
```

### Test Connectivity

```bash
# Test Sonnet
curl -s -X POST http://192.168.1.206:8091/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-sonnet-4-5","messages":[{"role":"user","content":"hi"}],"max_tokens":10}' \
  | jq .

# Test Opus
curl -s -X POST http://192.168.1.210:8092/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-opus-4-5","messages":[{"role":"user","content":"hi"}],"max_tokens":10}' \
  | jq .

# Test Haiku
curl -s -X POST http://192.168.1.211:8093/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"hi"}],"max_tokens":10}' \
  | jq .
```

## Advanced Configuration

### Adding Rate Limits (Example)

To add rate limiting to a specific model, create an AgentgatewayPolicy:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: claude-sonnet-ratelimit
  namespace: kgateway-system
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: claude-sonnet-backend
  rateLimit:
    requestsPerMinute: 100
```

### Adding Monitoring (Example)

Each gateway can have its own ServiceMonitor for Prometheus:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: claude-sonnet-gateway
  namespace: kgateway-system
spec:
  selector:
    matchLabels:
      app: claude-sonnet
  endpoints:
    - port: metrics
```

### Per-Model Network Policies (Example)

Restrict which services can access expensive models:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: claude-opus-access
  namespace: kgateway-system
spec:
  podSelector:
    matchLabels:
      app: claude-opus
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: trusted-apps
```

## Troubleshooting

### Gateway Not Getting IP

```bash
# Check LoadBalancer status
kubectl get svc -n kgateway-system

# Check gateway events
kubectl describe gateway claude-sonnet-gateway -n kgateway-system
```

### Route Not Working

```bash
# Check HTTPRoute status
kubectl get httproute claude-sonnet-route -n kgateway-system -o yaml

# Look for ResolvedRefs condition
kubectl get httproute claude-sonnet-route -n kgateway-system -o jsonpath='{.status.parents[0].conditions}'
```

### Backend Issues

```bash
# Check backend status
kubectl get agentgatewaybackend claude-sonnet-backend -n kgateway-system -o yaml

# Verify secret exists
kubectl get secret anthropic-secret -n kgateway-system
```

### 404 Errors

If you get "route not found":
- Verify the HTTPRoute has no `hostnames` field (or remove it)
- Check that the path matches `/v1/chat/*` or `/v1/completions/*`

### 500 Errors

If you get "no valid backends":
- Check that the AgentgatewayBackend is in `Accepted` status
- Verify the secret `anthropic-secret` exists and has valid credentials

## Benefits Summary

✅ **No nginx deployment** - Eliminates 3+ Kubernetes resources per setup
✅ **No /v1/models endpoint needed** - Model is implicit in the gateway
✅ **Model enforcement** - Client cannot request different models
✅ **Independent policies** - Rate limits, monitoring, network rules per model
✅ **Separate IPs** - Firewall rules and cost tracking per model
✅ **OpenAI-compatible** - Works with any OpenAI SDK or client
✅ **Simple architecture** - Gateway → Route → Backend → Anthropic API

## Comparison: Old vs New Architecture

### Old Architecture (Single Gateway with nginx)

```
Client → gateway-anthropic:8081
  ├─ /v1/models → nginx pod (static JSON)
  └─ /v1/chat → claude-ai-backend → Anthropic API
                (model specified by client)
```

**Resources Required:**
- 1 Gateway
- 1 AgentgatewayBackend (passthrough mode)
- 1 nginx Deployment
- 1 ConfigMap (models list)
- 1 Service (nginx)
- 2 HTTPRoutes

**Issues:**
- Requires nginx deployment just for `/v1/models`
- Model not enforced (client can request any model)
- All models share same rate limits/policies
- Cannot track usage per model easily

### New Architecture (Multi-Gateway)

```
Client → Dedicated Gateway per Model
  ├─ claude-sonnet:8091 → claude-sonnet-backend → Anthropic (sonnet)
  ├─ claude-opus:8092 → claude-opus-backend → Anthropic (opus)
  └─ claude-haiku:8093 → claude-haiku-backend → Anthropic (haiku)
```

**Resources Required:**
- 3 Gateways
- 3 AgentgatewayBackends (model hardcoded)
- 3 HTTPRoutes

**Advantages:**
- No nginx needed
- Model enforced at gateway level
- Independent policies per model
- Easy per-model usage tracking
- Simpler configuration

## Future Enhancements

### Add More Models

To add a new model (e.g., Claude Sonnet 3.5):

1. Add gateway in `gateway/claude-gateways.yaml`
2. Add backend in `backends/claude-backends.yaml` with hardcoded model
3. Add route in `httproute/claude-routes.yaml`
4. Update Wave Terminal config

### Add HTTPS

Enable TLS termination at the gateway:

```yaml
listeners:
  - name: https
    port: 8443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
        - name: claude-tls-cert
```

### Add Authentication

Add API key authentication at the gateway level using AgentgatewayPolicy.

## References

- [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
- [AgentGateway Documentation](https://docs.agentgateway.dev/)
- [Anthropic API Documentation](https://docs.anthropic.com/)
- [Wave Terminal AI Configuration](https://docs.waveterm.dev/waveai-modes)
