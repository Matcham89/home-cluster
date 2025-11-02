# Local Development Guide

Run the Kagent Slack bot locally on your machine for development and testing.

## Prerequisites

- **Python 3.8+** installed
- **Slack App** configured (see [README.md](README.md#slack-app-configuration))
- **Kagent** running in Kubernetes cluster
- **kubectl** access to your cluster

## Quick Start (5 minutes)

### 1. Port-Forward Kagent

Open a terminal and keep this running:

```bash
kubectl port-forward -n apps svc/kagent-controller 8083:8083
```

You should see:
```
Forwarding from 127.0.0.1:8083 -> 8083
Forwarding from [::1]:8083 -> 8083
```

**Keep this terminal open while developing.**

### 2. Setup Python Environment

```bash
# Clone/navigate to project
cd kagent-slack

# Create virtual environment
python3 -m venv venv

# Activate virtual environment
source venv/bin/activate  # On macOS/Linux
# OR
venv\Scripts\activate  # On Windows

# Install dependencies
pip install -r requirements.txt
```

### 3. Configure Environment

```bash
# Copy example config
cp .env.example .env
```

Edit `.env` with your tokens:

```bash
# Get these from https://api.slack.com/apps
SLACK_BOT_TOKEN=xoxb-your-bot-token-here
SLACK_APP_TOKEN=xapp-your-app-token-here

# Local port-forward endpoint
KAGENT_A2A_URL=http://localhost:8083/api/a2a/apps/k8s-agent
```

**Important:** Update `apps` and `k8s-agent` to match your setup:
- `apps` = namespace where Kagent is deployed
- `k8s-agent` = name of your agent

### 4. Run the Bot

```bash
python slack_bot.py
```

You should see:
```
2025-10-30 14:00:00 - INFO - ✓ Slack app initialized
2025-10-30 14:00:00 - INFO - 🚀 Starting Kagent Slack Bot...
2025-10-30 14:00:00 - INFO -    Kagent URL: http://localhost:8083/api/a2a/apps/k8s-agent/
2025-10-30 14:00:00 - INFO -    Bot token: xoxb-8039506410246-9...
2025-10-30 14:00:00 - INFO -    App token: xapp-1-A09Q4NC7F7B-9...
2025-10-30 14:00:00 - INFO - ⚡️ Kagent Slack Bot is running!
2025-10-30 14:00:00 - INFO -    Waiting for @kagent mentions in Slack...
2025-10-30 14:00:01 - INFO - ⚡️ Bolt app is running!
```

### 5. Test in Slack

1. **Invite bot to channel:**
   ```
   /invite @kagent
   ```

2. **Test conversation context:**
   ```
   @kagent list all namespaces
   @kagent how many pods in the first one?
   ```

   The bot should remember "the first one" refers to the first namespace!

3. **Watch terminal logs:**
   ```
   2025-10-30 14:01:00 - INFO - 🔔 Received app_mention
   2025-10-30 14:01:00 - INFO -    Channel: C081QPRR7ED
   2025-10-30 14:01:00 - INFO -    Thread: 1761860108.627629
   2025-10-30 14:01:00 - INFO - 🆕 Starting new conversation
   2025-10-30 14:01:00 - INFO - 📤 Sending message to Kagent
   2025-10-30 14:01:00 - INFO - 📊 Processed 7 events from stream
   2025-10-30 14:01:00 - INFO - 💬 Found agent response
   2025-10-30 14:01:01 - INFO - ✅ Message processed

   # Second message in same thread:
   2025-10-30 14:01:30 - INFO - 🔔 Received app_mention
   2025-10-30 14:01:30 - INFO - 🔄 Using existing contextId: 7d5e0706-...
   2025-10-30 14:01:30 - INFO - 📊 Processed 5 events from stream
   2025-10-30 14:01:30 - INFO - ✅ Message processed
   ```

## Development Workflow

### Making Changes

1. Edit `slack_bot.py`
2. Stop bot (Ctrl+C)
3. Restart bot (`python slack_bot.py`)
4. Test in Slack

### Debugging

**Enable debug logging:**

Edit `slack_bot.py` and change:
```python
logging.basicConfig(
    level=logging.DEBUG,  # Changed from INFO
    format='%(asctime)s - %(levelname)s - %(message)s'
)
```

**Test A2A endpoint directly:**
```bash
curl http://localhost:8083/api/a2a/apps/k8s-agent/.well-known/agent.json
```

Should return agent info (not 404).

**Test with specific message (returns SSE stream):**
```bash
curl -X POST http://localhost:8083/api/a2a/apps/k8s-agent/ \
  -H "Content-Type: application/json" \
  -H "Accept: text/event-stream" \
  -d '{
    "jsonrpc": "2.0",
    "method": "message/stream",
    "params": {
      "message": {
        "kind": "message",
        "role": "user",
        "parts": [{"kind": "text", "text": "hello"}],
        "messageId": "test-123",
        "metadata": {"displaySource": "user"}
      }
    },
    "id": 1
  }'
```

You'll see SSE events stream back:
```
event: task_status_update
data: {"result":{"contextId":"abc-123","status":{...}}}

event: task_status_update
data: {"result":{"status":{"message":{"role":"agent","parts":[{"text":"Hello!"}]}}}}
```

## Troubleshooting

### Port-forward disconnects

If you see "connection refused" errors:

```bash
# Check port-forward is running
lsof -i :8083

# If not, restart it
kubectl port-forward -n apps svc/kagent-controller 8083:8083
```

### Bot not receiving events

1. **Check Socket Mode is enabled:**
   - Go to https://api.slack.com/apps
   - Select your app → Socket Mode → Toggle should be ON

2. **Check Event Subscriptions:**
   - Event Subscriptions → Toggle should be ON
   - `app_mention` should be in "Subscribe to bot events"
   - Click "Reinstall to Workspace" if you made changes

3. **Check tokens:**
   ```bash
   # In your .env file
   echo $SLACK_BOT_TOKEN | cut -c1-20
   # Should start with: xoxb-

   echo $SLACK_APP_TOKEN | cut -c1-20
   # Should start with: xapp-
   ```

### Module not found errors

```bash
# Make sure venv is activated
source venv/bin/activate

# Reinstall dependencies
pip install -r requirements.txt
```

### Wrong namespace/agent

If you get 404 errors:

```bash
# Check what agents exist
kubectl get agents -A

# Update .env with correct namespace and agent name
KAGENT_A2A_URL=http://localhost:8083/api/a2a/<NAMESPACE>/<AGENT-NAME>
```

## Clean Up

When done developing:

```bash
# Stop the bot (Ctrl+C in terminal)

# Stop port-forward (Ctrl+C in port-forward terminal)

# Deactivate virtual environment
deactivate
```

## Next Steps

- Ready for production? See [KUBERNETES.md](KUBERNETES.md)
- Need help with Slack config? See [README.md](README.md#slack-app-configuration)
- Want to understand the code? Check out:
  - `KagentClient` class - handles A2A protocol and SSE parsing
  - `handle_mention` - Slack event handler
  - `_parse_stream` - SSE event processing

## Tips

- **Use tmux/screen** to keep port-forward running in background
- **Set up auto-reload** with `watchdog` for automatic restarts
- **Use ngrok** if you want to test without Socket Mode
- **Check Kagent logs** for agent-side issues:
  ```bash
  kubectl logs -n apps -l app=kagent-controller -f
  ```
