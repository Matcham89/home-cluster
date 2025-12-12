# Kagent Slack Bot

A minimal Slack bot that connects your workspace to Kagent's Kubernetes AI agents using the A2A (Agent2Agent) protocol. Ask questions about your cluster in natural language directly from Slack.

```
User in Slack: @kagent what pods are running in production?
                     ↓
              Slack Bot (this)
                     ↓
            Kagent AI Agent (A2A Protocol)
                     ↓
            Kubernetes API (kubectl)
                     ↓
         Response back to Slack thread
```

## Features

- ✅ **Natural Language Interface** - Ask questions like "@kagent what pods are running?"
- ✅ **Conversational Context** - Maintains conversation history within each thread
- ✅ **A2A Protocol** - Standard Agent2Agent communication with streaming support
- ✅ **Socket Mode** - No public URLs needed, works behind firewalls
- ✅ **Production Ready** - Clean architecture with proper error handling
- ✅ **Kubernetes Native** - Designed for cluster deployment

## Quick Links

- 📘 **[Local Development](LOCAL_DEV.md)** - Run locally with port-forward
- 🚀 **[Kubernetes Deployment](KUBERNETES.md)** - Production deployment guide
- ⚡ **[Quickstart](QUICKSTART.md)** - Get running in 5 minutes

## What You Need

- **Slack workspace** with admin access
- **Kagent** installed in Kubernetes
- **Python 3.8+** (for local dev) OR **Kubernetes cluster** (for production)

## Get Started

### Option 1: Local Development

Perfect for testing and development:

```bash
# 1. Port-forward Kagent
kubectl port-forward -n apps svc/kagent-controller 8083:8083 &

# 2. Setup and run bot
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
# Edit .env with your Slack tokens
python slack_bot.py
```

**See [LOCAL_DEV.md](LOCAL_DEV.md) for detailed instructions.**

### Option 2: Kubernetes Deployment

For production use:

```bash
# 1. Create secret with Slack tokens
kubectl create secret generic slack-credentials \
  --from-literal=bot-token='xoxb-your-token' \
  --from-literal=app-token='xapp-your-token' \
  --namespace=apps

# 2. Deploy
kubectl apply -f k8s-deployment.yaml

# 3. Check logs
kubectl logs -n apps -l app=kagent-slack-bot -f
```

**See [KUBERNETES.md](KUBERNETES.md) for detailed instructions.**

## Slack App Configuration

### Required Configuration (5 minutes)

1. **Create App** at https://api.slack.com/apps
   - Click "Create New App" → "From scratch"
   - Name: `kagent`, select workspace

2. **Add Bot Scopes** (OAuth & Permissions → Bot Token Scopes):
   - `app_mentions:read` - Detect @mentions
   - `chat:write` - Post messages
   - `channels:history` - Read history

3. **Enable Socket Mode** (Socket Mode → Toggle ON):
   - Generate token with `connections:write` scope
   - Save as `SLACK_APP_TOKEN`

4. **Enable Event Subscriptions** (Event Subscriptions → Toggle ON):
   - ⚠️ **CRITICAL**: Leave "Request URL" blank (we use Socket Mode)
   - Subscribe to bot events: `app_mention`
   - Click "Save Changes"

5. **Install App** (OAuth & Permissions):
   - Click "Reinstall to Workspace" → "Allow"
   - Copy Bot User OAuth Token as `SLACK_BOT_TOKEN`

### Test in Slack

```
/invite @kagent
@kagent list all namespaces
@kagent how many pods in the first one?  ← Remembers "first one" = first namespace!
```

Each Slack thread maintains its own conversation context with kagent.

## A2A Protocol Implementation

This bot implements the A2A (Agent2Agent) protocol with Server-Sent Events (SSE) streaming.

### JSON-RPC 2.0 Streaming Request

```json
{
  "jsonrpc": "2.0",
  "method": "message/stream",
  "params": {
    "message": {
      "kind": "message",
      "role": "user",
      "parts": [{"kind": "text", "text": "your question"}],
      "messageId": "unique-uuid",
      "contextId": "thread-context-id",  // For conversation continuity
      "metadata": {
        "displaySource": "user"
      }
    }
  },
  "id": 1
}
```

### SSE Response Format

The agent streams multiple events:

```
event: task_status_update
data: {"result":{"status":{"state":"submitted"},...}}

event: task_status_update
data: {"result":{"status":{"message":{"role":"agent","parts":[{"text":"response"}]}}}}

event: task_status_update
data: {"result":{"final":true,"status":{"state":"completed"}}}
```

**Key Implementation Details:**
- Method: `message/stream` (streaming, not `message/send`)
- Response: SSE (Server-Sent Events) format
- Context: `contextId` in message for conversation continuity
- Agent response: Found in `event.status.message.parts[0].text` where `role='agent'`
- Library: `sseclient-py` for proper SSE handling

See [A2A Protocol Specification](https://a2a-protocol.org/latest/specification/) for details.

## Architecture

```
┌─────────────────────┐
│  Slack (Browser)    │
│  @kagent what ...?  │
└──────────┬──────────┘
           │ WebSocket (Socket Mode)
           ↓
┌─────────────────────────────┐
│   slack_bot.py              │
│   ┌─────────────────────┐   │
│   │ Slack Event Handler │   │
│   │ - Receives mentions │   │
│   │ - Thread management │   │
│   └──────────┬──────────┘   │
│              │               │
│   ┌──────────▼──────────┐   │
│   │   KagentClient      │   │
│   │ - Builds request    │   │
│   │ - Parses SSE stream │   │
│   │ - Tracks contextId  │   │
│   └──────────┬──────────┘   │
└──────────────┼──────────────┘
               │ HTTP POST (A2A Protocol)
               │ JSON-RPC 2.0 + SSE stream
               ↓
┌───────────────────────────────┐
│  Kagent Controller (Port 8083)│
│  - Streams events (SSE)       │
│  - Maintains contextId        │
└──────────────┬────────────────┘
               │ Routes to agent
               ↓
┌───────────────────────────────┐
│  k8s-agent (AI Agent)         │
│  - Processes with context     │
│  - Uses MCP tools             │
└──────────────┬────────────────┘
               │ kubectl commands
               ↓
┌───────────────────────────────┐
│  Kubernetes API               │
│  - Gets resources             │
│  - Fetches logs               │
└───────────────────────────────┘
```

**Key Components:**
- **Slack Event Handler**: Receives @mentions, manages threads
- **KagentClient**: Encapsulates A2A protocol communication
- **SSE Parsing**: Handles streaming responses from kagent
- **Context Management**: Maps Slack threads to kagent contextIds

## Project Structure

```
kagent-slack/
├── slack_bot.py           # Main bot code (~310 lines)
│                          #   - KagentClient class
│                          #   - SSE stream parsing
│                          #   - Context management
├── requirements.txt       # Python dependencies
│                          #   - slack-bolt, requests
│                          #   - sseclient-py (SSE support)
├── Dockerfile            # Container image (2025 best practices)
├── k8s-deployment.yaml   # Kubernetes deployment
├── build.sh              # Build and push Docker image
├── .env.example          # Environment template
├── README.md             # This file (overview)
├── LOCAL_DEV.md          # Local development guide
├── KUBERNETES.md         # Production deployment guide
└── QUICKSTART.md         # 5-minute quickstart
```

## Troubleshooting

### Bot Not Responding

**Most common issue:** Event Subscriptions not configured

1. Go to https://api.slack.com/apps → Your App
2. Check "Event Subscriptions" → Toggle is ON
3. Verify `app_mention` is in "Subscribe to bot events"
4. Click "Reinstall to Workspace"
5. Restart bot

### Can't Connect to Kagent

```bash
# Test endpoint is reachable
curl http://localhost:8083/api/a2a/apps/k8s-agent/.well-known/agent.json

# Should return agent info (not 404)
```

### More Help

- **Local dev issues**: See [LOCAL_DEV.md](LOCAL_DEV.md#troubleshooting)
- **Kubernetes issues**: See [KUBERNETES.md](KUBERNETES.md#troubleshooting)
- **Slack config**: See [Slack API Docs](https://api.slack.com/docs)

## Contributing

Improvements welcome! The codebase is designed to be clean and maintainable.

**Current features:**
- ✅ Conversation context within threads
- ✅ SSE streaming support
- ✅ Clean class-based architecture
- ✅ Comprehensive error handling

**Areas for contribution:**
- Long-term conversation memory (Redis/database)
- Multi-agent support (switch agents mid-conversation)
- Slash commands (`/kagent ask ...`)
- Interactive buttons and forms
- Metrics and observability

## License

MIT License - Free to use and modify for your needs.

## Resources

- **Kagent**: https://kagent.dev/docs
- **A2A Protocol**: https://a2a-protocol.org
- **Slack Bolt**: https://slack.dev/bolt-python/
- **Socket Mode**: https://api.slack.com/apis/connections/socket

## Acknowledgments

Built with:
- Google's **A2A (Agent2Agent) Protocol**
- Slack's **Bolt framework** for Python
- **Kagent** AI agent platform

---

**Questions?** Open an issue or check the detailed guides:
- [LOCAL_DEV.md](LOCAL_DEV.md) - Local development
- [KUBERNETES.md](KUBERNETES.md) - Production deployment
- [QUICKSTART.md](QUICKSTART.md) - Quick reference
