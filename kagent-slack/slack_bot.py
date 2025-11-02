"""
Simple Slack bot that communicates with Kagent via A2A protocol.
User mentions @kagent in Slack -> Bot forwards to Kagent -> Response back to Slack
"""
import os
import json
import logging
from typing import Optional, Dict
import requests
from sseclient import SSEClient
from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler
from dotenv import load_dotenv

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Load environment variables
load_dotenv()

class KagentClient:
    def __init__(self, base_url: str, namespace: str = "kagent", agent_name: str = "k8s-agent"):
        self.base_url = base_url
        self.namespace = namespace
        self.agent_name = agent_name
        self.endpoint = f"{base_url}/api/a2a/{namespace}/{agent_name}/"
        self.thread_contexts: Dict[str, str] = {}  # Map thread_ts -> contextId
        
        logger.info(f"🔧 Kagent client initialized")
        logger.info(f"   Endpoint: {self.endpoint}")
    
    def send_message(self, text: str, thread_id: Optional[str] = None) -> Dict:
        """
        Send message to Kagent and extract response from SSE stream
        
        Returns:
            Dict with keys: response (str), status (str), contextId (str)
        """
        logger.info(f"📤 Sending message to Kagent")
        logger.info(f"   Thread ID: {thread_id}")
        logger.info(f"   Message: {text[:100]}...")
        
        # Prepare JSON-RPC 2.0 request
        payload = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "message/stream",
            "params": {
                "message": {
                    "role": "user",
                    "parts": [{"kind": "text", "text": text}],
                    "messageId": f"msg-{hash((text, thread_id))}"
                }
            }
        }
        
        # Include contextId for thread continuity
        if thread_id and thread_id in self.thread_contexts:
            payload["params"]["message"]["contextId"] = self.thread_contexts[thread_id]
            logger.info(f"🔄 Using existing contextId: {self.thread_contexts[thread_id]}")
        else:
            logger.info(f"🆕 Starting new conversation")
        
        # Make streaming request
        headers = {
            "Content-Type": "application/json",
            "Accept": "text/event-stream"
        }
        
        try:
            response = requests.post(
                self.endpoint,
                json=payload,
                headers=headers,
                stream=True,
                timeout=300
            )
            response.raise_for_status()
            
            # Parse SSE stream
            result = self._parse_stream(response, thread_id)
            
            logger.info(f"✅ Message processed")
            logger.info(f"   Status: {result['status']}")
            logger.info(f"   Context ID: {result['contextId']}")
            logger.info(f"   Response length: {len(result['response'] or '')}")
            
            return result
            
        except requests.exceptions.Timeout:
            logger.error(f"⏱️ Request timeout after 300s")
            return {
                'response': "Request timed out. Please try again.",
                'status': 'timeout',
                'contextId': None
            }
        except requests.exceptions.RequestException as e:
            logger.error(f"❌ Request failed: {e}")
            return {
                'response': f"Failed to connect to Kagent: {str(e)}",
                'status': 'error',
                'contextId': None
            }
    
    def _parse_stream(self, response, thread_id: Optional[str]) -> Dict:
        """
        Parse SSE events and extract agent response
        """
        client = SSEClient(response)
        agent_response = None
        context_id = None
        status = "unknown"
        event_count = 0
        
        logger.debug(f"📡 Starting SSE stream parsing")
        
        for event in client.events():
            # Skip empty events
            if not event.data or not event.data.strip():
                continue
            
            event_count += 1
            
            try:
                # Each event.data contains a JSON-RPC response
                json_rpc_response = json.loads(event.data)
                
                # Handle JSON-RPC errors
                if 'error' in json_rpc_response:
                    error = json_rpc_response['error']
                    logger.error(f"❌ JSON-RPC error: {error}")
                    return {
                        'response': f"Agent error: {error.get('message', 'Unknown error')}",
                        'status': 'error',
                        'contextId': context_id
                    }
                
                # Extract the actual event from the JSON-RPC wrapper
                event_data = json_rpc_response.get('result', {})
                
                if not event_data:
                    logger.warning(f"⚠️ Empty result in JSON-RPC response")
                    continue
                
                # Log event details
                logger.debug(f"📦 Event {event_count}: kind={event_data.get('kind')}, "
                           f"final={event_data.get('final')}, "
                           f"status={event_data.get('status', {}).get('state')}")
                
                # Store contextId for conversation continuity
                if 'contextId' in event_data:
                    context_id = event_data['contextId']
                    if thread_id:
                        self.thread_contexts[thread_id] = context_id
                
                # Track status
                if 'status' in event_data:
                    status = event_data['status'].get('state', status)
                    
                    # Check if this event contains the agent response
                    if 'message' in event_data['status']:
                        message = event_data['status']['message']
                        
                        # Only process agent messages (not user echoes)
                        if message.get('role') == 'agent':
                            # Extract text from parts
                            parts = message.get('parts', [])
                            if parts and len(parts) > 0:
                                agent_response = parts[0].get('text', '')
                                logger.debug(f"💬 Found agent response: {agent_response[:100]}...")
                
                # Check if this is the final event
                if event_data.get('final'):
                    logger.debug(f"🏁 Received final event")
                    break
                    
            except json.JSONDecodeError as e:
                logger.error(f"⚠️ Failed to parse event: {event.data[:200]}")
                continue
            except Exception as e:
                logger.error(f"⚠️ Error processing event: {e}")
                continue
        
        logger.info(f"📊 Processed {event_count} events from stream")
        
        return {
            'response': agent_response,
            'status': status,
            'contextId': context_id
        }


# Initialize Slack app
logger.info("🚀 Initializing Slack bot...")

SLACK_BOT_TOKEN = os.environ.get("SLACK_BOT_TOKEN")
SLACK_APP_TOKEN = os.environ.get("SLACK_APP_TOKEN")

# Support both configuration styles:
# 1. KAGENT_A2A_URL (full URL): http://host:port/api/a2a/namespace/agent
# 2. Separate components: KAGENT_BASE_URL + KAGENT_NAMESPACE + KAGENT_AGENT_NAME
KAGENT_A2A_URL = os.environ.get("KAGENT_A2A_URL")

if KAGENT_A2A_URL:
    # Parse the full URL to extract components
    # Format: http://host:port/api/a2a/namespace/agent
    logger.info(f"📋 Using KAGENT_A2A_URL: {KAGENT_A2A_URL}")
    
    # Extract base URL (everything before /api/a2a/)
    if "/api/a2a/" in KAGENT_A2A_URL:
        KAGENT_BASE_URL = KAGENT_A2A_URL.split("/api/a2a/")[0]
        # Extract namespace/agent from path
        path_parts = KAGENT_A2A_URL.split("/api/a2a/")[1].rstrip("/").split("/")
        KAGENT_NAMESPACE = path_parts[0] if len(path_parts) > 0 else "kagent"
        KAGENT_AGENT_NAME = path_parts[1] if len(path_parts) > 1 else "k8s-agent"
        
        logger.info(f"   Parsed base URL: {KAGENT_BASE_URL}")
        logger.info(f"   Parsed namespace: {KAGENT_NAMESPACE}")
        logger.info(f"   Parsed agent: {KAGENT_AGENT_NAME}")
    else:
        logger.error("❌ Invalid KAGENT_A2A_URL format. Expected: http://host:port/api/a2a/namespace/agent")
        exit(1)
else:
    # Use separate component variables (fallback)
    KAGENT_BASE_URL = os.environ.get("KAGENT_BASE_URL", "http://localhost:8083")
    KAGENT_NAMESPACE = os.environ.get("KAGENT_NAMESPACE", "kagent")
    KAGENT_AGENT_NAME = os.environ.get("KAGENT_AGENT_NAME", "k8s-agent")
    logger.info(f"📋 Using separate env vars")

if not SLACK_BOT_TOKEN or not SLACK_APP_TOKEN:
    logger.error("❌ Missing required environment variables: SLACK_BOT_TOKEN and/or SLACK_APP_TOKEN")
    exit(1)

app = App(token=SLACK_BOT_TOKEN)
kagent = KagentClient(
    base_url=KAGENT_BASE_URL,
    namespace=KAGENT_NAMESPACE,
    agent_name=KAGENT_AGENT_NAME
)

logger.info("✅ Slack app initialized")


@app.event("app_mention")
def handle_mention(event, say, logger):
    """
    Handle @kagent mentions in Slack
    """
    logger.info(f"🔔 Received app_mention")
    logger.info(f"   Channel: {event.get('channel')}")
    logger.info(f"   User: {event.get('user')}")
    logger.info(f"   Text: {event.get('text')}")
    
    # Get thread_ts: use existing thread or start new one
    thread_ts = event.get("thread_ts") or event.get("ts")
    logger.info(f"   Thread: {thread_ts}")
    
    # Extract user message (remove bot mention)
    user_message = event["text"]
    user_message = user_message.split(">", 1)[-1].strip()
    logger.info(f"   Cleaned message: {user_message}")
    
    if not user_message:
        say("Please provide a message after mentioning me!", thread_ts=thread_ts)
        return
    
    # Acknowledge receipt
    say("🤔 Processing your request...", thread_ts=thread_ts)
    
    try:
        # Send to Kagent and get response
        result = kagent.send_message(user_message, thread_id=thread_ts)
        
        if result['status'] == 'completed' and result['response']:
            say(result['response'], thread_ts=thread_ts)
        elif result['status'] == 'failed':
            say(f"❌ Task failed: {result['response']}", thread_ts=thread_ts)
        elif result['status'] in ['timeout', 'error']:
            say(result['response'], thread_ts=thread_ts)
        else:
            say(f"⚠️ No response received from agent (status: {result['status']})", thread_ts=thread_ts)
            
    except Exception as e:
        logger.error(f"❌ Error in handle_mention: {e}", exc_info=True)
        say(f"❌ Failed to process request: {str(e)}", thread_ts=thread_ts)


@app.event("message")
def handle_message_events(body, logger):
    """
    Handle other message events (for debugging)
    """
    logger.debug(f"Message event: {body.get('event', {}).get('type')}")


if __name__ == "__main__":
    logger.info("🎬 Starting Kagent Slack Bot...")
    logger.info(f"   Kagent: {KAGENT_BASE_URL}")
    logger.info(f"   Agent: {KAGENT_NAMESPACE}/{KAGENT_AGENT_NAME}")
    logger.info(f"   Bot Token: {'SET' if SLACK_BOT_TOKEN else 'NOT SET'}")
    logger.info(f"   App Token: {'SET' if SLACK_APP_TOKEN else 'NOT SET'}")
    
    handler = SocketModeHandler(app, SLACK_APP_TOKEN)
    logger.info("⚡ Bot is running! Waiting for @mentions...")
    handler.start()