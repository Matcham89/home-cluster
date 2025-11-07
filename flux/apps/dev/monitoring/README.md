# Monitoring Stack

## Overview

This monitoring stack provides comprehensive observability for the Kubernetes cluster using the Prometheus ecosystem for metrics and Loki for logs.

## Components

### Core Stack (kube-prometheus-stack)
- **Prometheus** - Time-series database and metrics collection
- **Alertmanager** - Alert handling and routing
- **Grafana** - Visualization and dashboards
- **kube-state-metrics** - Kubernetes object metrics
- **prometheus-node-exporter** - Node-level system metrics

### Logging Stack
- **Loki** - Log aggregation and storage
- **Promtail** - Log collection agent (DaemonSet on all nodes)
- **Loki Gateway** - NGINX-based gateway for Loki API

### Access
- **Cloudflare Tunnel** - Secure external access to Grafana (2 replicas for HA)

## Architecture

### Metrics Flow
```
Applications/Controllers
  ↓ (expose metrics on /metrics)
ServiceMonitor/PodMonitor (label: release=kube-prometheus-stack)
  ↓ (scrape config)
Prometheus (30s interval)
  ↓ (query)
Grafana Dashboards
```

### Logs Flow
```
Application Logs
  ↓ (stdout/stderr)
Container Runtime
  ↓ (/var/log/pods)
Promtail DaemonSet
  ↓ (push)
Loki Gateway
  ↓
Loki (with MinIO backend)
  ↓ (query)
Grafana
```

## Configuration

### Directory Structure
```
flux/apps/dev/monitoring/
├── kustomization.yaml          # Main kustomization
├── kube-prometheus-stack/      # Prometheus stack config
│   └── ks.yaml
├── grafana/                    # Loki/Promtail config
│   └── ks.yaml
├── cluster-secrets/            # Cloudflare tunnel secrets
│   └── ks.yaml
└── flux-alerts/               # Flux event notifications
    └── ks.yaml

flux/apps/base/monitoring/
├── kube-prometheus-stack/
│   ├── kube-prometheus-stack.yaml  # Main HelmRelease
│   ├── cloudflare-tunnel.yaml      # Tunnel deployment
│   └── ocirepository.yaml          # Chart source
├── grafana/
│   ├── loki.yaml                   # Loki HelmRelease
│   └── promtail.yaml               # Promtail HelmRelease
└── cluster-secrets/
```

### Namespace Configuration

The `monitoring` namespace is configured with:
- **No Istio injection** - Uses `namespace-no-istio` component
- **Prune disabled** - Prevents accidental deletion by Flux
- **CNI**: Standard Flannel CNI (not istio-cni)

### Scraping Configuration

Prometheus is configured to scrape:
- **ServiceMonitors** with label: `release: kube-prometheus-stack`
- **PodMonitors** with label: `release: kube-prometheus-stack`
- Default scrape interval: **30 seconds**
- Retention: **10 days**

### Custom Monitoring for Applications

To expose metrics from your application to Prometheus:

1. **Ensure metrics endpoint exists** (typically `/metrics` on a port)

2. **Create a PodMonitor** with the required label:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: my-app
  namespace: my-namespace
  labels:
    release: kube-prometheus-stack  # REQUIRED
spec:
  selector:
    matchLabels:
      app: my-app
  podMetricsEndpoints:
  - port: http-metrics
    interval: 30s
```

3. **OR Create a ServiceMonitor**:
```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: my-app
  namespace: my-namespace
  labels:
    release: kube-prometheus-stack  # REQUIRED
spec:
  selector:
    matchLabels:
      app: my-app
  endpoints:
  - port: http-metrics
    interval: 30s
```

## Accessing Services

### Grafana
- **URL**: Configured via Cloudflare Tunnel (check tunnel config)
- **Default Credentials**: Stored in cluster secrets
- **Dashboards**: Auto-discovered from ConfigMaps with label `grafana_dashboard: "1"`

### Prometheus
```bash
# Port-forward to access Prometheus UI
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# Access at http://localhost:9090
```

### Alertmanager
```bash
# Port-forward to access Alertmanager UI
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
# Access at http://localhost:9093
```

## Caveats and Important Notes

### 1. **Istio Sidecar Injection**

⚠️ The monitoring namespace **does NOT use Istio sidecars**. This is intentional to:
- Avoid circular dependencies (monitoring Istio requires monitoring to be up)
- Reduce complexity in the monitoring stack
- Prevent CNI issues during pod startup

If you need to add Istio in the future, you'll need to:
1. Update the namespace configuration
2. Ensure proper CNI configuration
3. Configure proper network policies

### 2. **CNI Configuration**

The cluster uses **Flannel CNI** (not istio-cni). If you see errors like:
```
failed to find plugin "istio-cni" in path
```

This indicates incorrect CNI configuration on the nodes. The CNI config should be:
```bash
# Location: /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist
# Should contain: type: "flannel" (not istio-cni)
```

### 3. **PodMonitor/ServiceMonitor Labels**

⚠️ **Critical**: All PodMonitors and ServiceMonitors **must** have the label:
```yaml
labels:
  release: kube-prometheus-stack
```

Without this label, Prometheus will **not** scrape the metrics endpoint.

### 4. **Loki Storage**

Loki uses **MinIO** for object storage within the cluster. This is suitable for development but consider:
- External S3-compatible storage for production
- Backup strategy for MinIO data
- Storage capacity planning

### 5. **Resource Consumption**

The monitoring stack is resource-intensive:
- **Prometheus**: Memory usage grows with number of time series
- **Loki**: Disk I/O intensive during log ingestion
- **Promtail**: Runs on every node as a DaemonSet

Monitor the monitoring stack itself!

### 6. **Grafana Dashboard Auto-Discovery**

Dashboards are auto-loaded from ConfigMaps with:
```yaml
metadata:
  labels:
    grafana_dashboard: "1"
  namespace: monitoring  # Must be in monitoring namespace
```

The sidecar scans every 60 seconds for new dashboards.

### 7. **Flux Control Plane Monitoring**

The Flux controllers expose Prometheus metrics. Ensure:
- PodMonitor exists in `flux-system` namespace
- Has label `release: kube-prometheus-stack`
- Dashboard namespace variable is set to `flux-system`

### 8. **Alertmanager Configuration**

Alertmanager is enabled but requires configuration for:
- Alert routing rules
- Notification receivers (Slack, email, etc.)
- Silencing rules

Configure via the HelmRelease values.

## Troubleshooting

### Pods Not Starting (CNI Errors)

**Symptom**: Pods stuck in `ContainerCreating` with `failed to find plugin "istio-cni"`

**Solution**: Check CNI configuration on worker nodes:
```bash
# Check CNI config
kubectl debug node/worker01 -it --image=alpine -- chroot /host cat /var/lib/rancher/k3s/agent/etc/cni/net.d/10-flannel.conflist

# Should show flannel plugin, not istio-cni
```

### Metrics Not Appearing in Grafana

**Checklist**:
1. Verify PodMonitor/ServiceMonitor has `release: kube-prometheus-stack` label
2. Check Prometheus targets: Port-forward and visit `/targets`
3. Verify the metrics endpoint is accessible from within the cluster
4. Check Prometheus logs for scrape errors
5. Ensure namespace variable in dashboard is correct

### Loki Not Receiving Logs

**Checklist**:
1. Verify Promtail DaemonSet is running on all nodes
2. Check Promtail logs for errors
3. Verify Loki gateway is accessible
4. Check Loki logs for ingestion errors
5. Verify MinIO is running and accessible

### High Memory Usage

**Prometheus** memory usage is based on:
- Number of time series being collected
- Scrape interval (lower = more memory)
- Retention period (longer = more memory)

**Solutions**:
- Reduce retention period
- Increase scrape interval for less critical metrics
- Use recording rules to pre-aggregate data
- Add resource limits carefully (can cause OOMKills)

## Maintenance

### Updating the Stack

The stack is managed by Flux and will auto-update based on:
- Chart version pinned in `ocirepository.yaml`
- HelmRelease reconciliation interval (1m)

To update:
1. Update chart version in `ocirepository.yaml`
2. Commit and push
3. Flux will reconcile automatically

### Backup Considerations

Important data to backup:
- Grafana dashboards (if not in ConfigMaps)
- Alertmanager configuration
- Prometheus data (if long-term retention needed)
- Loki data (MinIO volumes)

### Scaling

- **Prometheus**: Single replica (StatefulSet)
- **Loki**: Single replica (can be scaled for HA)
- **Promtail**: DaemonSet (auto-scales with nodes)
- **Cloudflare Tunnel**: 2 replicas for HA

## Additional Resources

- [kube-prometheus-stack Documentation](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack)
- [Loki Documentation](https://grafana.com/docs/loki/latest/)
- [Prometheus Operator](https://prometheus-operator.dev/)
- [Grafana Dashboards](https://grafana.com/grafana/dashboards/)
