# KGateway Observability Configuration

This directory contains the configuration for KGateway with OpenTelemetry (OTEL) observability stack integration.

## AgentGateway Configuration

### What is AgentGateway?

AgentGateway is a **Rust-based data plane proxy** specifically designed for AI/LLM workloads. It differs from the standard KGateway Envoy-based proxy in several key ways:

- **Purpose-built for AI**: Optimized for AI agent protocols (A2A - Agent-to-Agent), LLM inference routing, and MCP (Model Context Protocol)
- **Structured logging**: Outputs structured JSON logs natively with trace context
- **GenAI semantic conventions**: Follows OpenTelemetry GenAI semantic conventions for AI-specific observability
- **Lightweight**: Rust-based implementation optimized for AI workload patterns

### Why We Use GatewayParameters

The AgentGateway proxy requires **environment variable configuration** to enable OpenTelemetry integration, unlike standard Envoy-based proxies which can be configured entirely through HTTPListenerPolicy.

**Key files:**
- `gateway/gatewayparameters.yaml` - Defines OTEL configuration via environment variables
- `gateway/agentgateway.yaml` - Gateway resource that references the GatewayParameters
- `httplistenerspolicy/otel.yaml` - Access log policy (for future Envoy compatibility)
- `httplistenerspolicy/traces.yaml` - Tracing policy (for future Envoy compatibility)
- `referencegrants/otel.yaml` - Allows cross-namespace service references

### What We've Configured

#### GatewayParameters (`gateway/gatewayparameters.yaml`)

```yaml
spec:
  kube:
    agentgateway:
      enabled: true
      env:
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://otel-collector-collector.monitoring.svc.cluster.local:4317"
        - name: OTEL_EXPORTER_OTLP_PROTOCOL
          value: "grpc"
        - name: OTEL_SERVICE_NAME
          value: "agentgateway"
        - name: OTEL_TRACES_EXPORTER
          value: "otlp"
        - name: OTEL_LOGS_EXPORTER
          value: "otlp"
```

These environment variables configure the AgentGateway to:
- Send traces and logs to the OTEL collector in the `monitoring` namespace
- Use gRPC protocol for OTLP (OpenTelemetry Protocol)
- Identify itself as the "agentgateway" service in traces

#### Gateway Resource (`gateway/agentgateway.yaml`)

The Gateway links to the GatewayParameters via `infrastructure.parametersRef`:

```yaml
spec:
  gatewayClassName: agentgateway
  infrastructure:
    parametersRef:
      name: agentgateway-otel
      group: gateway.kgateway.dev
      kind: GatewayParameters
```

### Current Behavior

**What works:**
- ✅ AgentGateway logs structured JSON with trace context to stdout
- ✅ HTTP requests are logged with trace.id, span.id, and request metadata
- ✅ Environment variables are injected into the agentgateway pod
- ✅ OTEL collector is configured and ready to receive data

**What to expect:**
- **AI/LLM traces**: When AI extensions are invoked, traces with GenAI semantic conventions will be sent to Tempo via the OTEL collector
- **Structured logs**: AgentGateway outputs logs to stdout (not via OTEL); these should be collected by a log aggregator like Promtail

**Note:** AgentGateway's OTEL integration in v2.1 is primarily focused on **AI/LLM observability**. General HTTP access logs are written to stdout in structured format rather than sent via OTEL.

### Collecting AgentGateway Logs

To collect the structured logs output by AgentGateway, configure your log aggregator (e.g., Promtail) to scrape from the agentgateway pods:

```yaml
# Example Promtail scrape config
- job_name: agentgateway
  kubernetes_sd_configs:
    - role: pod
      namespaces:
        names:
          - kgateway
  relabel_configs:
    - source_labels: [__meta_kubernetes_pod_label_app]
      regex: agentgateway
      action: keep
```

## Envoy-Based KGateway

### When to Use Envoy-Based Gateway

Use the standard Envoy-based KGateway proxy when you need:
- **General HTTP/HTTPS traffic routing** (not AI-specific)
- **Full OTEL integration** via HTTPListenerPolicy alone
- **Rich Envoy features**: Rate limiting, advanced traffic management, WebAssembly filters
- **Direct OTEL access log export**: Access logs sent directly to OTEL collector
- **Established ecosystem**: Mature Envoy observability integrations

### Configuration Differences

#### Envoy-Based Gateway Setup

For an Envoy-based gateway, you **only need HTTPListenerPolicy** - no GatewayParameters required:

```yaml
# Standard KGateway (Envoy-based)
kind: Gateway
apiVersion: gateway.networking.k8s.io/v1
metadata:
  name: http-gateway
  namespace: kgateway
spec:
  gatewayClassName: kgateway  # Note: "kgateway" not "agentgateway"
  listeners:
  - protocol: HTTP
    port: 8080
    name: http
    allowedRoutes:
      namespaces:
        from: All
```

#### HTTPListenerPolicy for Envoy

The same HTTPListenerPolicy resources work with Envoy-based gateways:

```yaml
# Applies to Envoy proxy via HTTPListenerPolicy
apiVersion: gateway.kgateway.dev/v1alpha1
kind: HTTPListenerPolicy
metadata:
  name: logging-policy
  namespace: kgateway
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: http-gateway  # Target Envoy-based gateway
  accessLog:
  - openTelemetry:
      grpcService:
        backendRef:
          name: otel-collector-collector
          namespace: monitoring
          port: 4317
      logName: "http-gateway-access-logs"
```

### Key Differences Summary

| Feature | AgentGateway | Envoy-Based KGateway |
|---------|--------------|----------------------|
| **GatewayClass** | `agentgateway` | `kgateway` |
| **Primary Use Case** | AI/LLM workloads | General HTTP traffic |
| **OTEL Configuration** | GatewayParameters + HTTPListenerPolicy | HTTPListenerPolicy only |
| **Access Logs** | Stdout (structured JSON) | Direct OTEL export |
| **Traces** | AI/LLM semantic conventions | Standard HTTP spans |
| **Implementation** | Rust-based | Envoy proxy |
| **Protocols** | HTTP, A2A, MCP | HTTP, gRPC, TCP, TLS |

## ReferenceGrant

Both gateway types require a ReferenceGrant to allow cross-namespace service references:

```yaml
# referencegrants/otel.yaml
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-otel-collector-access
  namespace: monitoring  # Grant is in the target namespace
spec:
  from:
  - group: gateway.kgateway.dev
    kind: HTTPListenerPolicy
    namespace: kgateway  # Allow from kgateway namespace
  to:
  - group: ""
    kind: Service
    name: otel-collector-collector  # Allow access to this service
```

This allows HTTPListenerPolicy resources in the `kgateway` namespace to reference the OTEL collector service in the `monitoring` namespace.

## Architecture

```
┌─────────────────────┐
│   AgentGateway      │
│   (Rust proxy)      │
│                     │
│  AI/LLM requests    │
└──────────┬──────────┘
           │
           │ OTEL_EXPORTER_OTLP_ENDPOINT
           │ (via GatewayParameters env)
           │
           ▼
┌─────────────────────┐
│  OTEL Collector     │
│  (monitoring ns)    │
│                     │
│  Port 4317 (gRPC)   │
└──────────┬──────────┘
           │
           ├──────────┐
           ▼          ▼
    ┌──────────┐  ┌──────────┐
    │  Tempo   │  │   Loki   │
    │ (traces) │  │  (logs)  │
    └──────────┘  └──────────┘
```

## Troubleshooting

### Check AgentGateway OTEL Configuration

```bash
# Verify environment variables are set
kubectl get deployment agentgateway -n kgateway -o yaml | grep -A 10 OTEL_

# Check agentgateway logs
kubectl logs -n kgateway deployment/agentgateway --tail=50

# Verify GatewayParameters is linked
kubectl get gateway agentgateway -n kgateway -o yaml | grep -A 5 infrastructure:
```

### Check OTEL Collector

```bash
# Verify collector is receiving data
kubectl logs -n monitoring deployment/otel-collector-collector --tail=50

# Check collector service
kubectl get svc -n monitoring otel-collector-collector
```

### Verify ReferenceGrant

```bash
# Check ReferenceGrant exists
kubectl get referencegrant -n monitoring allow-otel-collector-access

# Check HTTPListenerPolicy status
kubectl get httplistenerpolicy -n kgateway
```

## References

- [KGateway v2.1 Release Notes](https://www.cncf.io/blog/2025/11/18/kgateway-v2-1-is-released/)
- [KGateway AgentGateway Tracing Docs](https://kgateway.dev/docs/main/agentgateway/llm/tracing/)
- [OpenTelemetry Documentation](https://opentelemetry.io/docs/)
- [Gateway API Specification](https://gateway-api.sigs.k8s.io/)
