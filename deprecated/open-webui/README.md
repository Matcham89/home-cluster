# Open WebUI for Ollama

Self-hosted Open WebUI connecting to Ollama through AgentGateway for full observability and token tracking.

## Architecture

- **Browser Access**: AgentGateway HTTPS (`https://open-webui.kubegit.com`)
- **Ollama API**: AgentGateway HTTP with OpenAI-compatible endpoint
- **Monitoring**: Prometheus metrics, Grafana dashboards

## Traffic Flow

```
Browser → Cloudflare → AgentGateway HTTPS (192.168.1.202:8443) → Open WebUI Service
Open WebUI Pod → AgentGateway HTTP (ollama.kubegit.com:8080) → Ollama (192.168.1.200:11434)
```

### Request Routing

1. **Browser → Open WebUI**:
   - Route: `open-webui` HTTPRoute in kgateway-system
   - Backend: `open-webui-backend` (static)
   - Listener: `https-openwebui` on port 8443

2. **Open WebUI → Ollama**:
   - `/v1/models`: `ollama-models` HTTPRoute → `ollama-passthrough` (static backend)
   - `/v1/chat/completions`: `ollama-api` HTTPRoute → `ollama-backend` (AI backend with token tracking)
   - `/v1/completions`: `ollama-api` HTTPRoute → `ollama-backend` (AI backend with token tracking)

## Components

### Local Files (this directory)

- `open-webui.yaml` - Namespace, Deployment, Service, PVC
- `istio-httproute.yaml` - **UNUSED** (kept for reference, using AgentGateway instead)
- `open-webui-referencegrant.yaml` - Allows kgateway HTTPRoutes to access open-webui Service

### Flux-Managed Resources

**Location**: `/flux/apps/base/kgateway-system/httproute/open-web-ui.yaml`

Contains:
- `open-webui` HTTPRoute (browser access)
- `open-webui-backend` AgentgatewayBackend (static)
- `ollama-models` HTTPRoute (model listing endpoint)
- `ollama-api` HTTPRoute (chat/completions endpoints)
- `ollama-backend` AgentgatewayBackend (AI backend with token tracking)
- `ollama-passthrough` AgentgatewayBackend (static passthrough for /v1/models)

**Location**: `/flux/apps/base/monitoring/kube-prometheus-stack/`

Contains:
- `prometheus-rules/open-webui.yaml` - Prometheus recording rules
- `dashboards/open-webui.yaml` - Grafana dashboard

## Deployment

### Initial Deployment

```bash
# Apply namespace, deployment, service, PVC
kubectl apply -f open-webui/open-webui.yaml

# Apply ReferenceGrant
kubectl apply -f open-webui/open-webui-referencegrant.yaml

# HTTPRoutes and backends are managed by Flux in:
# flux/apps/base/kgateway-system/httproute/open-web-ui.yaml
```

### Update Deployment

```bash
# Update the deployment
kubectl apply -f open-webui/open-webui.yaml

# Monitoring rules and dashboards auto-apply via Flux
```

## Features

### Token Tracking

All LLM requests through AgentGateway are tracked with:
- Input token count
- Output token count
- Model used (qwen2.5:14b, qwen2.5:32b, llama3.1:70b)
- Request duration
- Cost equivalent (what it would cost with paid APIs)

### Monitoring

**Grafana Dashboard**: "Open WebUI - Ollama Usage Tracking"
- Model usage distribution
- Token usage by model
- Request counts and response times
- Cost equivalent tracking

**Prometheus Metrics**:
```promql
# Example queries
openwebui:requests:total:5m
openwebui:input_tokens:by_model
openwebui:cost_equivalent_usd:daily
```

## Configuration

### Environment Variables

- `OPENAI_API_BASE_URLS`: `http://ollama.kubegit.com:8080/v1`
- `OPENAI_API_KEYS`: `sk-dummy` (required by Open WebUI, not used by Ollama)

### HostAliases

Open WebUI pod uses `hostAliases` to resolve `ollama.kubegit.com` to the AgentGateway ClusterIP (`10.107.96.13`).

## Available Models

- qwen2.5:14b
- qwen2.5:32b
- llama3.1:70b

Models are served by Ollama at `192.168.1.200:11434` and routed through AgentGateway for monitoring.

## Access

- **Web UI**: https://open-webui.kubegit.com
- **Grafana Dashboard**: Search for "Open WebUI" in Grafana
- **Prometheus**: Query `openwebui:*` metrics

## Notes

- Ollama is self-hosted (free), but we track token usage to understand cost equivalent
- All AI traffic is monitored and logged by AgentGateway
- Browser access goes through AgentGateway HTTPS listener
- Istio routes are kept for reference but not used
