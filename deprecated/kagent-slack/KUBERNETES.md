# Kubernetes Deployment Guide

Deploy Kagent Slack bot to your Kubernetes cluster for production use.

## Prerequisites

- **Kubernetes cluster** with Kagent installed
- **kubectl** configured and connected
- **Slack App** configured (see [README.md](README.md#slack-app-configuration))
- **Docker registry** access (optional, for custom builds)

## Quick Deployment (3 steps)

### Step 1: Create Secret

Create a Kubernetes secret with your Slack tokens:

```bash
kubectl create secret generic slack-credentials \
  --from-literal=bot-token='xoxb-your-bot-token-here' \
  --from-literal=app-token='xapp-your-app-token-here' \
  --namespace=apps
```

Replace:
- `xoxb-your-bot-token-here` - Bot User OAuth Token from Slack
- `xapp-your-app-token-here` - App-Level Token from Slack
- `apps` - Namespace where Kagent is deployed

**Verify secret was created:**
```bash
kubectl get secret slack-credentials -n apps
```

### Step 2: Deploy Bot

```bash
kubectl apply -f k8s-deployment.yaml
```

**Note:** If you built a custom Docker image, update the image in `k8s-deployment.yaml` first:
```yaml
image: your-registry/kagent-slack-bot:latest
```

### Step 3: Verify Deployment

```bash
# Check pod is running
kubectl get pods -n apps -l app=kagent-slack-bot

# View logs
kubectl logs -n apps -l app=kagent-slack-bot -f
```

Expected output:
```
✓ Slack app initialized
🚀 Starting Kagent Slack Bot...
   Kagent URL: http://kagent-controller.apps.svc.cluster.local:8083/api/a2a/apps/k8s-agent/
⚡️ Kagent Slack Bot is running!
⚡️ Bolt app is running!
```

## Test in Slack

```
/invite @kagent
@kagent list all namespaces
@kagent how many pods in the first one?
```

The bot should respond with context - it remembers "the first one" = first namespace!

**Note:** Each Slack thread maintains its own conversation context with kagent. Context is stored in-memory, so it resets when the pod restarts.

## Configuration

### Update Namespace or Agent

Edit `k8s-deployment.yaml` and modify the `KAGENT_A2A_URL`:

```yaml
- name: KAGENT_A2A_URL
  value: "http://kagent-controller.<NAMESPACE>.svc.cluster.local:8083/api/a2a/<NAMESPACE>/<AGENT-NAME>"
```

Example for different namespace:
```yaml
value: "http://kagent-controller.production.svc.cluster.local:8083/api/a2a/production/k8s-prod-agent"
```

### Update Resource Limits

In `k8s-deployment.yaml`:

```yaml
resources:
  requests:
    memory: "128Mi"  # Minimum memory
    cpu: "100m"      # Minimum CPU (0.1 core)
  limits:
    memory: "256Mi"  # Maximum memory
    cpu: "200m"      # Maximum CPU (0.2 cores)
```

Adjust based on your needs:
- Small workspace: Default values are fine
- Large workspace (100+ users): Increase to 512Mi memory, 500m CPU

### Multiple Replicas

For high availability:

```yaml
spec:
  replicas: 2  # Run 2 pods
```

**Note:** Slack Socket Mode maintains one connection, so multiple replicas won't distribute load but provide failover.

## Building Custom Image

If you modified `slack_bot.py` and want to deploy your changes:

### Option 1: Use build.sh

```bash
# Set your registry
export REGISTRY=docker.io/your-username
export TAG=v1.0.0

# Build and push
./build.sh
```

### Option 2: Manual Build

```bash
# Build
docker build -t your-registry/kagent-slack-bot:latest .

# Push
docker push your-registry/kagent-slack-bot:latest

# Update k8s-deployment.yaml with your image
# Then deploy
kubectl apply -f k8s-deployment.yaml
```

## Updating Tokens

If you need to rotate Slack tokens:

```bash
# Delete old secret
kubectl delete secret slack-credentials -n apps

# Create new secret with updated tokens
kubectl create secret generic slack-credentials \
  --from-literal=bot-token='xoxb-new-token' \
  --from-literal=app-token='xapp-new-token' \
  --namespace=apps

# Restart deployment to pick up new secret
kubectl rollout restart deployment/kagent-slack-bot -n apps

# Watch rollout
kubectl rollout status deployment/kagent-slack-bot -n apps
```

## Monitoring

### View Logs

```bash
# Follow logs in real-time
kubectl logs -n apps -l app=kagent-slack-bot -f

# View last 100 lines
kubectl logs -n apps -l app=kagent-slack-bot --tail=100

# View logs from specific pod
kubectl logs -n apps kagent-slack-bot-xxxxx-xxxxx
```

**Look for context management logs:**
```
🆕 Starting new conversation
🔄 Using existing contextId: 7d5e0706-...
📊 Processed 7 events from stream
💬 Found agent response
```

### Check Pod Status

```bash
# List pods
kubectl get pods -n apps -l app=kagent-slack-bot

# Describe pod (shows events and errors)
kubectl describe pod -n apps -l app=kagent-slack-bot

# Get pod details
kubectl get pod -n apps -l app=kagent-slack-bot -o yaml
```

### View Events

```bash
kubectl get events -n apps --sort-by='.lastTimestamp' | grep kagent-slack-bot
```

## Troubleshooting

### Pod Not Starting

**Check events:**
```bash
kubectl describe pod -n apps -l app=kagent-slack-bot
```

Common issues:
- **ImagePullBackOff**: Docker image not accessible
  - Solution: Check image name, ensure registry access
- **CrashLoopBackOff**: Bot crashing on startup
  - Solution: Check logs with `kubectl logs`
- **Pending**: Can't schedule pod
  - Solution: Check cluster resources

### Bot Not Responding

**Check logs:**
```bash
kubectl logs -n apps -l app=kagent-slack-bot --tail=50
```

Look for:
- `✓ Slack app initialized` - Tokens are valid
- `⚡️ Bolt app is running!` - Socket Mode connected
- `🔔 Received app_mention event` - Events are coming through

**If no events received:**
1. Verify Socket Mode is enabled in Slack app
2. Check Event Subscriptions has `app_mention`
3. Reinstall app to workspace after config changes

### Can't Connect to Kagent

**Check service exists:**
```bash
kubectl get svc kagent-controller -n apps
```

**Test from within cluster:**
```bash
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://kagent-controller.apps.svc.cluster.local:8083/api/a2a/apps/k8s-agent/.well-known/agent.json
```

Should return agent info (not 404 or connection refused).

### Secret Not Found

```bash
# Check secret exists
kubectl get secret slack-credentials -n apps

# View secret (base64 encoded)
kubectl get secret slack-credentials -n apps -o yaml

# Check secret has correct keys
kubectl get secret slack-credentials -n apps -o jsonpath='{.data}' | jq keys
# Should show: ["app-token", "bot-token"]
```

## Security Best Practices

### Use Namespace Isolation

Deploy bot in same namespace as Kagent for network policies:

```bash
# Create namespace if needed
kubectl create namespace apps

# Deploy everything in apps namespace
kubectl apply -f k8s-deployment.yaml -n apps
```

### Limit Permissions

The bot doesn't need any Kubernetes permissions. Default ServiceAccount is fine.

### External Secret Management

For production, consider external secret managers:

**Using Sealed Secrets:**
```bash
# Install sealed-secrets controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Create sealed secret
kubectl create secret generic slack-credentials \
  --from-literal=bot-token='xoxb-...' \
  --from-literal=app-token='xapp-...' \
  --dry-run=client -o yaml | \
  kubeseal -o yaml > sealed-secret.yaml

# Apply sealed secret
kubectl apply -f sealed-secret.yaml -n apps
```

**Using External Secrets Operator:**
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: slack-credentials
  namespace: apps
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore
  target:
    name: slack-credentials
  data:
  - secretKey: bot-token
    remoteRef:
      key: slack/bot-token
  - secretKey: app-token
    remoteRef:
      key: slack/app-token
```

### Enable Pod Security Standards

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: apps
  labels:
    pod-security.kubernetes.io/enforce: restricted
```

## Scaling Considerations

### Horizontal Scaling

**Not recommended** for this bot because:
- Slack Socket Mode = one connection per bot
- Multiple replicas won't distribute load
- Can cause duplicate message processing

**Use replicas=1** or **replicas=2** for failover only.

### Vertical Scaling

Increase resources if needed:

```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "200m"
  limits:
    memory: "512Mi"
    cpu: "500m"
```

### Monitoring Resource Usage

```bash
# Check current usage
kubectl top pod -n apps -l app=kagent-slack-bot

# View metrics
kubectl describe pod -n apps -l app=kagent-slack-bot | grep -A 5 "Requests\|Limits"
```

## Backup and Disaster Recovery

### Backup Configuration

```bash
# Export secret (excluding sensitive data)
kubectl get secret slack-credentials -n apps -o yaml > backup-secret.yaml

# Export deployment
kubectl get deployment kagent-slack-bot -n apps -o yaml > backup-deployment.yaml
```

### Restore

```bash
# Restore secret
kubectl apply -f backup-secret.yaml

# Restore deployment
kubectl apply -f backup-deployment.yaml
```

## Uninstalling

```bash
# Delete deployment
kubectl delete deployment kagent-slack-bot -n apps

# Delete secret
kubectl delete secret slack-credentials -n apps
```

## Next Steps

- **Monitor metrics**: Set up Prometheus/Grafana
- **Add alerting**: Configure PagerDuty/Opsgenie for bot failures
- **Multiple agents**: Deploy additional bots for different agents
- **Custom commands**: Extend `slack_bot.py` with slash commands
- **Persistent context**: Add Redis for conversation history across pod restarts
- **Advanced features**: Implement file uploads, interactive buttons, or forms

## Support

- **Kagent Issues**: https://github.com/kagent-ai/kagent/issues
- **Slack API**: https://api.slack.com/docs
- **This bot**: Check logs first, then open an issue in your repo
