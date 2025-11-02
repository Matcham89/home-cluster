# Kagent Slack Bot - Quickstart

Get your Slack bot running in **5 minutes**. Choose your deployment method:

## Prerequisites

- Slack workspace with admin access
- Kagent installed in Kubernetes
- Python 3.8+ (for local) OR kubectl access (for K8s)

## Step 1: Create Slack App (2 min)

1. Go to https://api.slack.com/apps → **Create New App** → **From scratch**
2. Name: `kagent`, select workspace

**Add Scopes** (OAuth & Permissions → Bot Token Scopes):
- `app_mentions:read`
- `chat:write`
- `channels:history`

**Enable Socket Mode** (Socket Mode → Toggle ON):
- Generate token with `connections:write` scope
- Save token (starts with `xapp-`)

**Enable Events** ⚠️ CRITICAL:
- Event Subscriptions → Toggle ON
- Leave "Request URL" BLANK
- Subscribe to bot events: `app_mention`
- Click "Save Changes"

**Install App** (OAuth & Permissions):
- Click "Reinstall to Workspace" → Allow
- Save Bot Token (starts with `xoxb-`)

## Step 2: Choose Deployment Method

### Option A: Local Development (Testing)

```bash
# Port-forward Kagent
kubectl port-forward -n apps svc/kagent-controller 8083:8083 &

# Setup bot
cd kagent-slack
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Configure
cp .env.example .env
# Edit .env with your tokens:
#   SLACK_BOT_TOKEN=xoxb-...
#   SLACK_APP_TOKEN=xapp-...

# Run
python slack_bot.py
```

✅ **Done!** See [LOCAL_DEV.md](LOCAL_DEV.md) for detailed guide.

### Option B: Kubernetes (Production)

```bash
# Create secret
kubectl create secret generic slack-credentials \
  --from-literal=bot-token='xoxb-your-token' \
  --from-literal=app-token='xapp-your-token' \
  --namespace=apps

# Deploy
kubectl apply -f k8s-deployment.yaml

# Check logs
kubectl logs -n apps -l app=kagent-slack-bot -f
```

✅ **Done!** See [KUBERNETES.md](KUBERNETES.md) for detailed guide.

## Step 3: Test in Slack (1 min)

```
/invite @kagent
@kagent list all namespaces
@kagent how many pods in the first one?
```

Bot should respond with context! It remembers "the first one" refers to the first namespace. 🎉

**Each Slack thread = separate conversation with full context.**

## Troubleshooting

### Not responding?
1. Check **Event Subscriptions** has `app_mention`
2. Click **Reinstall to Workspace**
3. Restart bot

### Can't connect?
```bash
# Test endpoint
curl http://localhost:8083/api/a2a/apps/k8s-agent/.well-known/agent.json
```

## What's Next?

- **Detailed local setup**: [LOCAL_DEV.md](LOCAL_DEV.md)
- **Production deployment**: [KUBERNETES.md](KUBERNETES.md)
- **Full documentation**: [README.md](README.md)

## A2A Protocol Reference

The bot uses `message/stream` method with SSE (Server-Sent Events):

```json
{
  "method": "message/stream",
  "params": {
    "message": {
      "kind": "message",
      "role": "user",
      "parts": [{"kind": "text", "text": "your question"}],
      "messageId": "uuid",
      "contextId": "thread-context-id"
    }
  }
}
```

**Key points:**
- Method: `message/stream` (streaming with SSE)
- Context: `contextId` maintains conversation across messages
- Response: Streamed as multiple SSE events
- Agent reply: In `event.status.message.parts[0].text` where `role='agent'`
- Library: `sseclient-py` handles SSE parsing

## Project Files

```
kagent-slack/
├── slack_bot.py           # Main bot (~310 lines)
│                          #   - KagentClient class
│                          #   - SSE parsing
│                          #   - Context management
├── requirements.txt       # Dependencies (includes sseclient-py)
├── k8s-deployment.yaml   # K8s deployment
├── Dockerfile            # Container image
├── README.md             # Overview
├── LOCAL_DEV.md          # Local dev guide
├── KUBERNETES.md         # K8s deployment guide
└── QUICKSTART.md         # This file
```

---

**Need Help?**
- Local dev: [LOCAL_DEV.md](LOCAL_DEV.md#troubleshooting)
- Kubernetes: [KUBERNETES.md](KUBERNETES.md#troubleshooting)
- Slack config: [README.md](README.md#slack-app-configuration)
