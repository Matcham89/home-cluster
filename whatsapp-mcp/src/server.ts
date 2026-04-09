import express, { Request, Response } from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { z } from "zod";
import makeWASocket, {
  useMultiFileAuthState,
  DisconnectReason,
  WASocket,
  fetchLatestBaileysVersion,
} from "@whiskeysockets/baileys";
import pino from "pino";
import { mkdirSync } from "fs";
import qrcode from "qrcode-terminal";
import { randomUUID } from "crypto";

const AUTH_DIR = process.env.AUTH_DIR ?? "/data/auth";
const PORT = parseInt(process.env.PORT ?? "3000", 10);
const log = pino({ name: "whatsapp-mcp" });

const ALLOWED_SENDERS = new Set(["18253657006"]);

let waSocket: WASocket | null = null;
let connectionState: "open" | "connecting" | "closed" = "closed";

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

async function connectToWhatsApp(attempt = 0): Promise<void> {
  if (attempt >= 5) {
    log.error("Max reconnect attempts (5) reached, crashing for K8s restart");
    process.exit(1);
  }

  mkdirSync(AUTH_DIR, { recursive: true });

  const { state, saveCreds } = await useMultiFileAuthState(AUTH_DIR);
  const { version } = await fetchLatestBaileysVersion();
  log.info({ version }, "Using WhatsApp Web version");

  const sock = makeWASocket({
    version,
    auth: state,
    logger: pino({ level: "silent" }) as any,
  });

  waSocket = sock;
  connectionState = "connecting";

  sock.ev.on("creds.update", saveCreds);

  sock.ev.on("messages.upsert", async ({ messages, type }) => {
    if (type !== "notify") return;

    for (const msg of messages) {
      if (msg.key.fromMe) continue;

      const jid = msg.key.remoteJid;
      if (!jid) continue;

      if (jid.endsWith("@g.us")) continue;

      const phone = jid.replace("@s.whatsapp.net", "");
      if (!ALLOWED_SENDERS.has(phone)) {
        log.warn({ phone: `***${phone.slice(-4)}` }, "Ignored message from non-allowlisted sender");
        continue;
      }

      const text =
        msg.message?.conversation ??
        msg.message?.extendedTextMessage?.text ??
        null;

      if (!text) continue;

      log.info({ phone: `***${phone.slice(-4)}` }, "Received message, forwarding to k8s-agent");

      try {
        const reply = await forwardToK8sAgent(text);
        await waSocket!.sendMessage(jid, { text: reply });
        log.info({ phone: `***${phone.slice(-4)}` }, "Reply sent");
      } catch (err) {
        const error = err instanceof Error ? err.message : String(err);
        log.error({ phone: `***${phone.slice(-4)}`, error }, "Failed to send reply");
      }
    }
  });

  sock.ev.on("connection.update", async ({ connection, lastDisconnect, qr }) => {
    if (qr) {
      log.info("[whatsapp-mcp] No session found. Scan QR code to link device.");
      qrcode.generate(qr, { small: true });
    }

    if (connection === "open") {
      connectionState = "open";
      log.info("WhatsApp connection open");
    } else if (connection === "close") {
      connectionState = "closed";
      waSocket = null;

      const statusCode = (lastDisconnect?.error as any)?.output?.statusCode;
      if (statusCode === DisconnectReason.loggedOut) {
        log.error("Logged out from WhatsApp — delete /data/auth and re-scan QR");
        process.exit(1);
      }

      const delay = Math.min(1000 * 2 ** attempt, 30_000);
      log.info({ attempt: attempt + 1, delayMs: delay }, "Connection closed, reconnecting");
      await new Promise((r) => setTimeout(r, delay));
      connectToWhatsApp(attempt + 1);
    }
  });
}

const sendMessageSchema = {
  phone: z
    .string()
    .describe("Phone number in E.164 format without the + sign. Example: 14031234567"),
  message: z.string().describe("Plain text message body to send."),
};

// Each MCP connection needs its own McpServer instance — the SDK only allows one
// transport per server. This factory registers the tool on a fresh instance.
function createMcpServer(): McpServer {
  const server = new McpServer({ name: "whatsapp-mcp", version: "1.0.0" });

  // Baileys' deep recursive types exceed tsc's instantiation depth limit; cast to bypass
  (server.tool as Function)(
    "send_whatsapp_message",
    "Send a plain-text WhatsApp message to a phone number via a linked device session.",
    sendMessageSchema,
    async ({ phone, message }: { phone: string; message: string }) => {
      if (!ALLOWED_SENDERS.has(phone)) {
        log.warn({ phone: `***${phone.slice(-4)}` }, "Rejected send to non-allowlisted number");
        return {
          content: [{ type: "text", text: `Error: phone ${phone} is not in the allowlist.` }],
          isError: true,
        };
      }

      if (connectionState !== "open" || !waSocket) {
        return {
          content: [{ type: "text", text: "Error: WhatsApp socket not connected. Check pod logs." }],
          isError: true,
        };
      }

      const jid = `${phone}@s.whatsapp.net`;
      const truncated = `***${phone.slice(-4)}`;

      try {
        await waSocket.sendMessage(jid, { text: message });
        log.info({ phone: truncated, ts: new Date().toISOString() }, "Message sent");
        return {
          content: [{ type: "text", text: `Message sent to ${phone}` }],
        };
      } catch (err) {
        const error = err instanceof Error ? err.message : String(err);
        log.error({ phone: truncated, error }, "Send failed");
        return {
          content: [{ type: "text", text: `Error: ${error}` }],
          isError: true,
        };
      }
    }
  );

  return server;
}

// Express + Streamable HTTP transport
const app = express();
app.use(express.json());

const transports: Record<string, { transport: StreamableHTTPServerTransport; server: McpServer }> = {};

app.post("/mcp", async (req: Request, res: Response) => {
  const sessionId = req.headers["mcp-session-id"] as string | undefined;

  if (sessionId && transports[sessionId]) {
    await transports[sessionId].transport.handleRequest(req, res, req.body);
    return;
  }

  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => randomUUID(),
    onsessioninitialized: (id) => {
      transports[id] = { transport, server };
    },
  });

  transport.onclose = () => {
    if (transport.sessionId) delete transports[transport.sessionId];
  };

  const server = createMcpServer();
  await server.connect(transport);
  await transport.handleRequest(req, res, req.body);
});

app.get("/mcp", async (req: Request, res: Response) => {
  const sessionId = req.headers["mcp-session-id"] as string | undefined;
  if (!sessionId || !transports[sessionId]) {
    res.status(400).json({ error: "Missing or unknown mcp-session-id" });
    return;
  }
  await transports[sessionId].transport.handleRequest(req, res);
});

app.delete("/mcp", async (req: Request, res: Response) => {
  const sessionId = req.headers["mcp-session-id"] as string | undefined;
  if (sessionId && transports[sessionId]) {
    await transports[sessionId].transport.close();
    delete transports[sessionId];
  }
  res.status(200).end();
});

// SSE transport — used by Google ADK Python agent runtime
const sseTransports: Record<string, SSEServerTransport> = {};

app.get("/sse", async (req: Request, res: Response) => {
  const transport = new SSEServerTransport("/message", res);
  sseTransports[transport.sessionId] = transport;
  res.on("close", () => delete sseTransports[transport.sessionId]);
  const server = createMcpServer();
  await server.connect(transport);
});

app.post("/message", async (req: Request, res: Response) => {
  const sessionId = req.query.sessionId as string;
  const transport = sseTransports[sessionId];
  if (!transport) {
    res.status(404).json({ error: "Session not found" });
    return;
  }
  await transport.handlePostMessage(req, res, req.body);
});

app.get("/healthz", (_req: Request, res: Response) => {
  if (connectionState === "open") {
    res.status(200).json({ status: "ok", connection: connectionState });
  } else {
    res.status(503).json({ status: "degraded", connection: connectionState });
  }
});

app.listen(PORT, () => {
  log.info({ port: PORT }, "HTTP server listening");
  connectToWhatsApp();
});
