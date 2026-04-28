# Multi-Gateway Deployment Guide

This directory contains configuration for deploying dedicated gateways per AI provider.

## Architecture

**New Setup (Multi-Gateway)**:
```
Open WebUI → gateway-anthropic (port 8081) → Claude API
          → gateway-ollama (port 8082) → Ollama Server
```

**Benefits**:
- ✅ Per-provider cost tracking
- ✅ Independent scaling and fault isolation
- ✅ Cleaner metrics separation
- ✅ Provider-specific rate limiting and policies

## Files Created

### Gateway Resources
- `gateway-anthropic.yaml` - Dedicated gateway for Claude (Anthropic)
- `gateway-ollama.yaml` - Dedicated gateway for Ollama

### Routes and Backends
- `routes-and-backends.yaml` - HTTPRoutes and AgentgatewayBackends for both providers
- `claude-models-service.yaml` - Static model list service for Claude

### Application
- `open-webui-updated.yaml` - Updated Open WebUI deployment for multi-gateway

### Monitoring
- `prometheus-rules-multi-gateway.yaml` - Per-provider metrics and cost tracking

## Deployment Steps

### Phase 1: Deploy Gateways

```bash
# 1. Deploy the two new gateways
kubectl apply -f gateway-anthropic.yaml
kubectl apply -f gateway-ollama.yaml

# 2. Wait for gateways to be ready
kubectl wait --for=condition=Programmed gateway/gateway-anthropic -n kgateway-system --timeout=60s
kubectl wait --for=condition=Programmed gateway/gateway-ollama -n kgateway-system --timeout=60s

# 3. Get the gateway ClusterIP addresses
kubectl get svc -n kgateway-system -l "gateway.networking.k8s.io/gateway-name in (gateway-anthropic,gateway-ollama)"
```

### Phase 2: Update Open WebUI Configuration

The gateways will create Kubernetes Services. You need to update the `open-webui-updated.yaml` file with the correct ClusterIP addresses:

```bash
# Get the ClusterIP addresses
ANTHROPIC_IP=$(kubectl get svc -n kgateway-system -l "gateway.networking.k8s.io/gateway-name=gateway-anthropic" -o jsonpath='{.items[0].spec.clusterIP}')
OLLAMA_IP=$(kubectl get svc -n kgateway-system -l "gateway.networking.k8s.io/gateway-name=gateway-ollama" -o jsonpath='{.items[0].spec.clusterIP}')

echo "Anthropic Gateway IP: $ANTHROPIC_IP"
echo "Ollama Gateway IP: $OLLAMA_IP"

# Update the open-webui-updated.yaml file
sed -i "s/GATEWAY_ANTHROPIC_IP/$ANTHROPIC_IP/g" open-webui-updated.yaml
sed -i "s/GATEWAY_OLLAMA_IP/$OLLAMA_IP/g" open-webui-updated.yaml
```

### Phase 3: Deploy Routes, Backends, and Open WebUI

```bash
# 1. Deploy routes and backends
kubectl apply -f routes-and-backends.yaml
kubectl apply -f claude-models-service.yaml

# 2. Deploy updated Open WebUI
kubectl apply -f open-webui-updated.yaml

# 3. Wait for Open WebUI to be ready
kubectl rollout status deployment/open-webui -n open-webui
```

### Phase 4: Deploy Monitoring

```bash
# Deploy per-provider Prometheus rules
kubectl apply -f prometheus-rules-multi-gateway.yaml
```

## Verification

### Test Claude Endpoint
```bash
kubectl exec -n open-webui deployment/open-webui -- \
  curl -s http://claude.kubegit.com:8081/v1/models
```

### Test Ollama Endpoint
```bash
kubectl exec -n open-webui deployment/open-webui -- \
  curl -s http://ollama.kubegit.com:8082/v1/models
```

### Check Metrics
```bash
# Claude metrics
kubectl run curl-test --image=curlimages/curl:latest --rm -i --restart=Never -- \
  curl -s "http://kube-prometheus-stack-prometheus.monitoring:9090/api/v1/query?query=openwebui:anthropic:conversations:hourly"

# Ollama metrics
kubectl run curl-test --image=curlimages/curl:latest --rm -i --restart=Never -- \
  curl -s "http://kube-prometheus-stack-prometheus.monitoring:9090/api/v1/query?query=openwebui:ollama:conversations:hourly"

# Cost metrics
kubectl run curl-test --image=curlimages/curl:latest --rm -i --restart=Never -- \
  curl -s "http://kube-prometheus-stack-prometheus.monitoring:9090/api/v1/query?query=openwebui:anthropic:cost_usd:daily"
```

## Cost Tracking

### Anthropic (Claude) Pricing
- **Claude Sonnet 4.5**: $3.00/1M input, $15.00/1M output
- **Claude Opus 4.5**: $15.00/1M input, $75.00/1M output
- Using blended rate in Prometheus: $3/1M input, $15/1M output

### Ollama
- **Actual Cost**: $0 (self-hosted)
- **Equivalent Cost**: Calculated using Claude Sonnet pricing for comparison

### Available Metrics
- `openwebui:anthropic:cost_usd:hourly` - Claude cost per hour
- `openwebui:anthropic:cost_usd:daily` - Claude cost per day
- `openwebui:anthropic:cost_usd:weekly` - Claude cost per week
- `openwebui:anthropic:cost_usd:monthly` - Claude cost per month
- `openwebui:ollama:cost_equivalent_usd:daily` - Ollama equivalent cost (for comparison)
- `openwebui:total:cost_usd:daily` - Total actual cost (Anthropic only)

### Cost Alerts
- **Warning**: Claude daily cost > $10
- **Warning**: Claude weekly cost > $50

## Gateway Configuration

### Anthropic Gateway
- **Name**: `gateway-anthropic`
- **Port**: 8081
- **Hostname**: `claude.kubegit.com`
- **Routes**: `/v1/models`, `/v1/chat`, `/v1/completions`

### Ollama Gateway
- **Name**: `gateway-ollama`
- **Port**: 8082
- **Hostname**: `ollama.kubegit.com`
- **Routes**: `/v1/models`, `/v1/chat`, `/v1/completions`

## Cleanup (Rollback)

To rollback to the original single gateway:

```bash
# Delete multi-gateway resources
kubectl delete -f routes-and-backends.yaml
kubectl delete -f gateway-anthropic.yaml
kubectl delete -f gateway-ollama.yaml

# Restore original Open WebUI
kubectl apply -f open-webui.yaml
```

## Phase 2: Flux Migration

After testing, move these files to `/flux/apps/base/`:
- Gateways → `/flux/apps/base/kgateway-system/gateway/`
- Routes/Backends → `/flux/apps/base/kgateway-system/httproute/`
- Prometheus Rules → `/flux/apps/base/monitoring/kube-prometheus-stack/prometheus-rules/`
