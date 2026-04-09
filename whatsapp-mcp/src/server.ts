import express, { Request, Response } from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
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

let waSocket: WASocket | null = null;
let connectionState: "open" | "connecting" | "closed" = "closed";

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

// MCP Server
const mcpServer = new McpServer({ name: "whatsapp-mcp", version: "1.0.0" });

const sendMessageSchema = {
  phone: z
    .string()
    .describe("Phone number in E.164 format without the + sign. Example: 14031234567"),
  message: z.string().describe("Plain text message body to send."),
};

// Baileys' deep recursive types exceed tsc's instantiation depth limit; cast to bypass
(mcpServer.tool as Function)(
  "send_whatsapp_message",
  "Send a plain-text WhatsApp message to a phone number via a linked device session.",
  sendMessageSchema,
  async ({ phone, message }: { phone: string; message: string }) => {
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

// Express + Streamable HTTP transport
const app = express();
app.use(express.json());

const transports: Record<string, StreamableHTTPServerTransport> = {};

app.post("/mcp", async (req: Request, res: Response) => {
  const sessionId = req.headers["mcp-session-id"] as string | undefined;

  if (sessionId && transports[sessionId]) {
    await transports[sessionId].handleRequest(req, res, req.body);
    return;
  }

  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: () => randomUUID(),
    onsessioninitialized: (id) => {
      transports[id] = transport;
    },
  });

  transport.onclose = () => {
    if (transport.sessionId) delete transports[transport.sessionId];
  };

  await mcpServer.connect(transport);
  await transport.handleRequest(req, res, req.body);
});

app.get("/mcp", async (req: Request, res: Response) => {
  const sessionId = req.headers["mcp-session-id"] as string | undefined;
  if (!sessionId || !transports[sessionId]) {
    res.status(400).json({ error: "Missing or unknown mcp-session-id" });
    return;
  }
  await transports[sessionId].handleRequest(req, res);
});

app.delete("/mcp", async (req: Request, res: Response) => {
  const sessionId = req.headers["mcp-session-id"] as string | undefined;
  if (sessionId && transports[sessionId]) {
    await transports[sessionId].close();
    delete transports[sessionId];
  }
  res.status(200).end();
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
