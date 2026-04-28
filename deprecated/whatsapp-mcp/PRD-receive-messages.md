# PRD: WhatsApp Message Receive → k8s-agent

## Goal

Extend the existing `whatsapp-mcp` pod to receive incoming WhatsApp messages and forward
them to the `k8s-agent` in the kagent namespace, returning the agent's response to the
sender. No new pods, no new CRDs — purely an extension of the existing service.

---

## Current State

- `whatsapp-mcp` already maintains a persistent Baileys socket (`waSocket`)
- Socket already handles `connection.update` and `creds.update`
- Outbound send works via `send_whatsapp_message` MCP tool
- NetworkPolicy: egress on 443 only (WhatsApp Web); ingress from kagent ns on 3000
- Phone allowlist already in place: `18253657006`

---

## What Changes

### 1. `server.ts` — Receive handler

Add a `messages.upsert` listener inside `connectToWhatsApp`, alongside the existing event
handlers. No new libraries needed — use `node-fetch` (already available in Node 20 as
global `fetch`) for the A2A call.

```typescript
sock.ev.on("messages.upsert", async ({ messages, type }) => {
  if (type !== "notify") return; // ignore history sync

  for (const msg of messages) {
    if (msg.key.fromMe) continue; // ignore our own outbound messages

    const jid = msg.key.remoteJid;
    if (!jid) continue;

    // Extract phone number — strip @s.whatsapp.net or @g.us (groups ignored)
    if (jid.endsWith("@g.us")) continue; // no group chats

    const phone = jid.replace("@s.whatsapp.net", "");
    if (!ALLOWED_SENDERS.has(phone)) {
      log.warn({ phone: `***${phone.slice(-4)}` }, "Ignored message from non-allowlisted sender");
      continue;
    }

    const text =
      msg.message?.conversation ??
      msg.message?.extendedTextMessage?.text ??
      null;

    if (!text) continue; // ignore media/stickers/reactions

    log.info({ phone: `***${phone.slice(-4)}` }, "Received message, forwarding to k8s-agent");

    const reply = await forwardToK8sAgent(text);
    await waSocket.sendMessage(jid, { text: reply });
    log.info({ phone: `***${phone.slice(-4)}` }, "Reply sent");
  }
});
```

**`ALLOWED_SENDERS`** — same set as `ALLOWED_PHONES`, defined once at module scope:
```typescript
const ALLOWED_PHONES = new Set(["18253657006"]);
// reuse for both send allowlist and receive allowlist
```

**`forwardToK8sAgent`** — simple A2A JSON-RPC call (no SDK needed):
```typescript
async function forwardToK8sAgent(text: string): Promise<string> {
  const K8S_AGENT_URL = process.env.K8S_AGENT_URL ?? "http://k8s-agent.kagent:8080";

  try {
    const res = await fetch(K8S_AGENT_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: randomUUID(),
        method: "message/send",
        params: {
          message: {
            role: "user",
            parts: [{ kind: "text", text }],
          },
        },
      }),
    });

    if (!res.ok) throw new Error(`k8s-agent returned ${res.status}`);

    const data: any = await res.json();

    // A2A response: result.status.message.parts[0].text
    const reply: string =
      data?.result?.status?.message?.parts?.[0]?.text ??
      data?.result?.artifacts?.[0]?.parts?.[0]?.text ??
      "No response from k8s-agent";

    return reply;
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    log.error({ error }, "Failed to contact k8s-agent");
    return `Error: could not reach k8s-agent — ${error}`;
  }
}
```

---

### 2. Network policies

**New: `allow-whatsapp-mcp-to-k8s-agent.yaml`**
Egress from whatsapp-mcp to k8s-agent on 8080:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-whatsapp-mcp-to-k8s-agent
spec:
  podSelector:
    matchLabels:
      app: whatsapp-mcp
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: k8s-agent
      ports:
        - port: 8080
          protocol: TCP
```

**Updated: `allow-whatsapp-mcp-egress.yaml`**
Consolidate 443 (WhatsApp Web) and 8080 (k8s-agent) into one policy, or keep as two
separate files (prefer separate — easier to reason about).

**New: `allow-whatsapp-mcp-ingress-to-k8s-agent.yaml`** (ingress side on k8s-agent)
Check whether k8s-agent already allows intra-namespace ingress. If not, add:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-whatsapp-mcp-to-k8s-agent
spec:
  podSelector:
    matchLabels:
      app: k8s-agent
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: whatsapp-mcp
      ports:
        - port: 8080
          protocol: TCP
```

Add both files to `flux/apps/base/network-policies/kagent/kustomization.yaml`.

---

### 3. Deployment — env var

Add `K8S_AGENT_URL` to the deployment for easy override without a rebuild:
```yaml
env:
  - name: K8S_AGENT_URL
    value: "http://k8s-agent.kagent:8080"
```

---

## What Does NOT Change

| Component | Status |
|---|---|
| Dockerfile | No change |
| MCP tool `send_whatsapp_message` | No change |
| PVC / auth | No change |
| Service | No change |
| `istio.io/use-waypoint: none` | Keep as-is |
| RemoteMCPServer CRD | No change |
| Phone allowlist (outbound) | No change — reuse for inbound |

---

## Security

- Only messages from `ALLOWED_SENDERS` are processed — all others are silently dropped and
  logged as warnings
- Group messages (`@g.us`) are explicitly rejected
- Only plain text messages are forwarded — media/stickers/reactions are ignored
- k8s-agent is reachable only from `app: whatsapp-mcp` via dedicated NetworkPolicy
- Egress policy is additive (existing 443 rule unchanged)
- No new ingress surface on whatsapp-mcp

---

## Error handling

| Failure | Behaviour |
|---|---|
| k8s-agent unreachable | Send error message back to WhatsApp sender |
| k8s-agent returns non-200 | Send error message back to WhatsApp sender |
| Malformed A2A response | Return fallback string, log the raw response |
| WhatsApp send fails on reply | Log error, do not crash |

---

## Out of scope (future)

- Conversation context / session continuity across messages
- Multiple allowed senders
- Routing to different agents based on message content
- Media/image handling
- Group chat support

---

## Implementation order

1. Check whether `k8s-agent` NetworkPolicy already allows intra-namespace ingress
2. Add `allow-whatsapp-mcp-to-k8s-agent.yaml` (egress) + ingress policy if needed
3. Update `kustomization.yaml` for network policies
4. Update `server.ts` — add `ALLOWED_SENDERS`, `forwardToK8sAgent`, `messages.upsert` handler
5. Add `K8S_AGENT_URL` env var to `deployment.yaml`
6. Build and push image
7. Apply network policies, then rollout restart
8. Smoke test: send a WhatsApp message from `18253657006`, confirm k8s-agent reply arrives
