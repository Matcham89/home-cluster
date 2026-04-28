#!/bin/bash
set -e

echo "=================================="
echo "Multi-Gateway Deployment Script"
echo "=================================="
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Change to script directory
cd "$(dirname "$0")"

echo "Step 1: Deploying Gateways..."
echo "------------------------------"
kubectl apply -f gateway-anthropic.yaml
kubectl apply -f gateway-ollama.yaml
echo ""

echo "Step 2: Waiting for gateways to be ready..."
echo "--------------------------------------------"
kubectl wait --for=condition=Programmed gateway/gateway-anthropic -n kgateway-system --timeout=60s
kubectl wait --for=condition=Programmed gateway/gateway-ollama -n kgateway-system --timeout=60s
echo -e "${GREEN}✓ Gateways are ready${NC}"
echo ""

echo "Step 3: Getting gateway ClusterIP addresses..."
echo "-----------------------------------------------"
sleep 5  # Give time for services to be created

# Get the ClusterIP addresses
ANTHROPIC_IP=$(kubectl get svc -n kgateway-system -l "gateway.networking.k8s.io/gateway-name=gateway-anthropic" -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null || echo "")
OLLAMA_IP=$(kubectl get svc -n kgateway-system -l "gateway.networking.k8s.io/gateway-name=gateway-ollama" -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null || echo "")

if [ -z "$ANTHROPIC_IP" ] || [ -z "$OLLAMA_IP" ]; then
    echo -e "${RED}✗ Failed to get gateway IPs${NC}"
    echo "Listing all services in kgateway-system:"
    kubectl get svc -n kgateway-system
    exit 1
fi

echo -e "${GREEN}Anthropic Gateway IP: $ANTHROPIC_IP${NC}"
echo -e "${GREEN}Ollama Gateway IP: $OLLAMA_IP${NC}"
echo ""

echo "Step 4: Updating Open WebUI configuration..."
echo "---------------------------------------------"
# Create a temporary file with updated IPs
cp open-webui-updated.yaml open-webui-updated-temp.yaml
sed -i.bak "s/GATEWAY_ANTHROPIC_IP/$ANTHROPIC_IP/g" open-webui-updated-temp.yaml
sed -i.bak "s/GATEWAY_OLLAMA_IP/$OLLAMA_IP/g" open-webui-updated-temp.yaml
rm -f open-webui-updated-temp.yaml.bak
echo -e "${GREEN}✓ Updated hostAliases with gateway IPs${NC}"
echo ""

echo "Step 5: Deploying routes and backends..."
echo "-----------------------------------------"
kubectl apply -f routes-and-backends.yaml
kubectl apply -f claude-models-service.yaml
echo -e "${GREEN}✓ Routes and backends deployed${NC}"
echo ""

echo "Step 6: Deploying updated Open WebUI..."
echo "----------------------------------------"
kubectl apply -f open-webui-updated-temp.yaml
echo ""

echo "Step 7: Waiting for Open WebUI rollout..."
echo "------------------------------------------"
kubectl rollout status deployment/open-webui -n open-webui --timeout=120s
echo -e "${GREEN}✓ Open WebUI is ready${NC}"
echo ""

echo "Step 8: Deploying Prometheus rules..."
echo "--------------------------------------"
kubectl apply -f prometheus-rules-multi-gateway.yaml
echo -e "${GREEN}✓ Prometheus rules deployed${NC}"
echo ""

# Clean up temp file
rm -f open-webui-updated-temp.yaml

echo "=================================="
echo "Verification"
echo "=================================="
echo ""

echo "Testing Claude endpoint..."
if kubectl exec -n open-webui deployment/open-webui -- curl -s http://claude.kubegit.com:8081/v1/models --max-time 5 | grep -q "claude"; then
    echo -e "${GREEN}✓ Claude endpoint working${NC}"
else
    echo -e "${YELLOW}⚠ Claude endpoint test failed (may need to wait a moment)${NC}"
fi

echo ""
echo "Testing Ollama endpoint..."
if kubectl exec -n open-webui deployment/open-webui -- curl -s http://ollama.kubegit.com:8082/v1/models --max-time 5 | grep -q "qwen\|llama"; then
    echo -e "${GREEN}✓ Ollama endpoint working${NC}"
else
    echo -e "${YELLOW}⚠ Ollama endpoint test failed (server may be down)${NC}"
fi

echo ""
echo "=================================="
echo "Deployment Complete!"
echo "=================================="
echo ""
echo "Gateway Configuration:"
echo "  • Anthropic (Claude): claude.kubegit.com:8081 → $ANTHROPIC_IP"
echo "  • Ollama:             ollama.kubegit.com:8082 → $OLLAMA_IP"
echo ""
echo "Next Steps:"
echo "  1. Access Open WebUI: https://open-webui.kubegit.com"
echo "  2. Check Grafana dashboard for per-provider metrics"
echo "  3. Monitor costs with: kubectl run curl-test --image=curlimages/curl:latest --rm -i --restart=Never -- curl -s 'http://kube-prometheus-stack-prometheus.monitoring:9090/api/v1/query?query=openwebui:anthropic:cost_usd:daily'"
echo ""
