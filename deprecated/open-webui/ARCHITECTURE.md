# Open WebUI Architecture

## 🎯 Complete Traffic Flow

### Browser Access (AgentGateway HTTPS)
```
User Browser
    ↓
Cloudflare (https://open-webui.kubegit.com)
    ↓
AgentGateway HTTPS Listener (192.168.1.202:8443)
    ↓ HTTPRoute: open-webui (kgateway-system)
    ↓ AgentgatewayBackend: open-webui-backend (static)
Open WebUI Service (open-webui.open-webui:80)
    ↓
Open WebUI Pod (10.244.x.x:8080)
```

### AI/LLM Queries (AgentGateway HTTP with Token Tracking)
```
Open WebUI Pod
    ↓ Environment: OPENAI_API_BASE_URLS=http://ollama.kubegit.com:8080/v1
    ↓ HostAlias: ollama.kubegit.com → 10.107.96.13 (agentgateway ClusterIP)
    ↓
AgentGateway HTTP Listener (port 8080)
    ↓
┌─────────────────────────────────────────────────────────┐
│ Request Router (based on path)                          │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  GET /v1/models                                         │
│    ↓ HTTPRoute: ollama-models                          │
│    ↓ AgentgatewayBackend: ollama-passthrough (static)  │
│    → Direct passthrough (no AI parsing)                │
│                                                          │
│  POST /v1/chat/completions                             │
│    ↓ HTTPRoute: ollama-api                             │
│    ↓ AgentgatewayBackend: ollama-backend (AI)          │
│    → Token tracking + monitoring ✓                     │
│                                                          │
│  POST /v1/completions                                   │
│    ↓ HTTPRoute: ollama-api                             │
│    ↓ AgentgatewayBackend: ollama-backend (AI)          │
│    → Token tracking + monitoring ✓                     │
│                                                          │
└─────────────────────────────────────────────────────────┘
    ↓
Ollama Server (192.168.1.200:11434)
    ↓ OpenAI-compatible endpoint
Returns: JSON with token usage
```

## 📊 Benefits

### AgentGateway (All Traffic)
- ✅ **Unified Gateway**: Both browser and API traffic through one gateway
- ✅ **TLS Termination**: HTTPS for browser access
- ✅ **Observability**: Prometheus metrics for all requests

### AI Backend (LLM Requests)
- ✅ **Token Tracking**: Input/output tokens per request
- ✅ **Model Monitoring**: Track which models are used (qwen2.5:14b, qwen2.5:32b, llama3.1:70b)
- ✅ **Performance Metrics**: Request duration, rate limiting
- ✅ **Cost Analysis**: Calculate equivalent cost if using paid APIs
- ✅ **Grafana Dashboard**: Real-time usage visualization

### Static Backend (/v1/models)
- ✅ **Fast Passthrough**: No parsing overhead for model listing
- ✅ **Compatibility**: Works with GET requests (no body)

## 🔧 Components

### AgentGateway Resources (kgateway-system namespace)

**Gateway Definition**:
- Listener `http`: Port 8080 (for Ollama API traffic)
- Listener `https-openwebui`: Port 8443 (for browser access)
- Service ClusterIP: `10.107.96.13`
- LoadBalancer IP: `192.168.1.202`

**HTTPRoutes**:
1. `open-webui` - Browser access to Open WebUI
   - Hostname: `open-webui.kubegit.com`
   - Listener: `https-openwebui` (port 8443)
   - Backend: `open-webui-backend` (static)

2. `ollama-models` - Model listing endpoint
   - Hostname: `ollama.kubegit.com`
   - Path: `/v1/models` (exact match)
   - Listener: `http` (port 8080)
   - Backend: `ollama-passthrough` (static)

3. `ollama-api` - Chat and completion endpoints
   - Hostname: `ollama.kubegit.com`
   - Paths: `/v1/chat/*`, `/v1/completions`
   - Listener: `http` (port 8080)
   - Backend: `ollama-backend` (AI)

**AgentgatewayBackends**:
1. `open-webui-backend` (static)
   - Host: `open-webui.open-webui.svc.cluster.local`
   - Port: 80

2. `ollama-passthrough` (static)
   - Host: `192.168.1.200`
   - Port: 11434
   - Purpose: Fast passthrough for /v1/models

3. `ollama-backend` (AI)
   - Provider: OpenAI-compatible
   - Host: `192.168.1.200`
   - Port: 11434
   - Features: Token tracking, model monitoring

### Open WebUI Resources (open-webui namespace)

**Deployment**:
- Image: `ghcr.io/open-webui/open-webui:main`
- Replicas: 1
- Resources: 512Mi-2Gi RAM, 250m-1000m CPU

**Environment Variables**:
- `OPENAI_API_BASE_URLS`: `http://ollama.kubegit.com:8080/v1`
- `OPENAI_API_KEYS`: `sk-dummy`

**HostAliases**:
- `ollama.kubegit.com` → `10.107.96.13` (agentgateway ClusterIP)

**Service**:
- Type: ClusterIP
- Port: 80 → Pod: 8080

**PVC**:
- Name: `open-webui-data`
- Size: 5Gi
- Access: ReadWriteOnce

### Monitoring Resources (monitoring namespace)

**PrometheusRule**: `open-webui-metrics`
- Recording rules for token usage
- Model-specific metrics
- Cost equivalent calculations

**Grafana Dashboard**: `open-webui-dashboard`
- ConfigMap: `open-webui-dashboard`
- Dashboard UID: `open-webui-usage`
- Title: "Open WebUI - Ollama Usage Tracking"

## 🧪 Testing

### Test Browser Access
```bash
curl -I https://open-webui.kubegit.com
# Should return: 200 OK
```

### Test Model Listing
```bash
kubectl exec -n open-webui deployment/open-webui -- \
  curl -s http://ollama.kubegit.com:8080/v1/models
# Should return: JSON with qwen2.5:14b, qwen2.5:32b, llama3.1:70b
```

### Test Chat Endpoint with Token Tracking
```bash
kubectl exec -n open-webui deployment/open-webui -- \
  curl -s http://ollama.kubegit.com:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"qwen2.5:14b","messages":[{"role":"user","content":"test"}],"stream":false}'
# Should return: JSON with usage.prompt_tokens and usage.completion_tokens
```

### Monitor AgentGateway Logs
```bash
kubectl logs -n kgateway-system deployment/agentgateway -f | grep ollama
# Look for: gen_ai.usage.input_tokens and gen_ai.usage.output_tokens
```

### Check Prometheus Metrics
```promql
# Total requests in last 5 minutes
openwebui:requests:total:5m

# Token usage by model
openwebui:input_tokens:by_model
openwebui:output_tokens:by_model

# Cost equivalent
openwebui:cost_equivalent_usd:daily
```

## 📝 Configuration Files

### Local (this directory)
- `open-webui.yaml` - Deployment, Service, PVC, Namespace
- `open-webui-referencegrant.yaml` - Allow kgateway to access open-webui Service
- `istio-httproute.yaml` - **UNUSED** (kept for reference)

### Flux (GitOps)
- `flux/apps/base/kgateway-system/httproute/open-web-ui.yaml` - HTTPRoutes and AgentgatewayBackends
- `flux/apps/base/monitoring/kube-prometheus-stack/prometheus-rules/open-webui.yaml` - Prometheus rules
- `flux/apps/base/monitoring/kube-prometheus-stack/dashboards/open-webui.yaml` - Grafana dashboard

## 🔒 Security

- ✅ Browser traffic encrypted via HTTPS (TLS termination at AgentGateway)
- ⚠️  Ollama API traffic unencrypted HTTP (internal cluster traffic)
- ⚠️  Ollama server traffic unencrypted HTTP to 192.168.1.200:11434
- 💡 Consider: Moving Ollama into cluster or adding VPN/WireGuard

## 📈 Metrics Available

### Request Metrics
- `agentgateway_gen_ai_client_operation_duration_count` - Request count
- `agentgateway_gen_ai_client_operation_duration_sum` - Total duration

### Token Metrics
- `agentgateway_gen_ai_client_token_usage_sum{gen_ai_token_type="input"}` - Input tokens
- `agentgateway_gen_ai_client_token_usage_sum{gen_ai_token_type="output"}` - Output tokens

### Labels
- `route` - HTTPRoute name (e.g., `kgateway-system/ollama-api`)
- `gen_ai_request_model` - Model used (e.g., `qwen2.5:14b`)
- `gen_ai_provider_name` - Provider (e.g., `openai`)

### Recording Rules (Prometheus)
All prefixed with `openwebui:*`:
- Token usage (5m, hourly, daily)
- Request counts by model
- Average duration by model
- Cost equivalent calculations

## 🎯 Key Design Decisions

1. **OpenAI-Compatible Endpoint**: Uses Ollama's `/v1/*` endpoints instead of native `/api/*` for token tracking
2. **Split HTTPRoutes**: Separate routes for `/v1/models` (static) and `/v1/chat/*` (AI backend) for optimal performance
3. **HostAliases**: Pod-level DNS override to route `ollama.kubegit.com` to AgentGateway ClusterIP
4. **Cost Tracking**: Even though Ollama is free, we track equivalent cost for comparison with cloud APIs
5. **Unified Gateway**: Both browser and API traffic through AgentGateway (not Istio)

## 🚀 Future Enhancements

- [ ] Move Ollama into Kubernetes cluster
- [ ] Add authentication/authorization for Open WebUI
- [ ] Implement rate limiting per user
- [ ] Add request/response caching
- [ ] Multi-replica Open WebUI deployment
- [ ] Database backend for Open WebUI (currently using PVC)
