import express, { Request, Response } from "express";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { z } from "zod";
import makeWASocket, {
  useMultiFileAuthState,
  DisconnectReason,
  WASocket,
} from "@whiskeysockets/baileys";
import pino from "pino";
import { mkdirSync, readdirSync } from "fs";
import qrcode from "qrcode-terminal";

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

  const sock = makeWASocket({
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
        content: [
          {
            type: "text",
            text: "Error: WhatsApp socket not connected. Check pod logs.",
          },
        ],
        isError: true,
      };
    }

    const jid = `${phone}@s.whatsapp.net`;
    const truncated = `***${phone.slice(-4)}`;

    try {
      await waSocket.sendMessage(jid, { text: message });
      log.info(
        { phone: truncated, ts: new Date().toISOString() },
        "Message sent"
      );
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

// Express + SSE transport
const app = express();
app.use(express.json());

const transports: Record<string, SSEServerTransport> = {};

app.get("/sse", async (req: Request, res: Response) => {
  const transport = new SSEServerTransport("/message", res);
  transports[transport.sessionId] = transport;
  res.on("close", () => delete transports[transport.sessionId]);
  await mcpServer.connect(transport);
});

app.post("/message", async (req: Request, res: Response) => {
  const sessionId = req.query.sessionId as string;
  const transport = transports[sessionId];
  if (!transport) {
    res.status(404).json({ error: "Session not found" });
    return;
  }
  await transport.handlePostMessage(req, res);
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
