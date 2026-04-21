/**
 * Streamable HTTP transport for the wg0 MCP server.
 *
 * Each incoming session is tied to a bearer token (wg0_pat_… for
 * Phase 1; OAuth-issued tokens in Phase 2). A fresh Wg0Client +
 * Server pair is created per session and cached by MCP session id.
 *
 * Listens on PORT (default 8090). Exposes a single path: /mcp
 * (GET for SSE, POST for JSON-RPC requests, DELETE to end session).
 *
 * The brain URL is read from WG0_BRAIN_URL (default
 * https://connect.wg0.io). For in-cluster traffic set this to the
 * docker-compose service name, e.g. http://brain:8000.
 */
import { randomUUID } from "node:crypto";
import http from "node:http";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";

import { Wg0Client } from "./client.js";
import { createMcpServer } from "./server-factory.js";

const brainUrl = process.env.WG0_BRAIN_URL ?? "https://connect.wg0.io";
const port = parseInt(process.env.PORT ?? "8090", 10);
const publicUrl =
  process.env.WG0_MCP_PUBLIC_URL?.replace(/\/$/, "") ?? "https://mcp.wg0.io";

interface Session {
  server: Awaited<ReturnType<typeof createMcpServer>>["server"];
  transport: StreamableHTTPServerTransport;
  client: Wg0Client;
  apiKey: string;
}

const sessions = new Map<string, Session>();

function extractBearer(req: http.IncomingMessage): string | null {
  const h = req.headers.authorization ?? req.headers.Authorization;
  if (!h || Array.isArray(h)) return null;
  const m = /^Bearer\s+(.+)$/i.exec(h);
  return m ? m[1].trim() : null;
}

async function readBody(req: http.IncomingMessage): Promise<unknown> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      if (chunks.length === 0) return resolve(undefined);
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw.trim()) return resolve(undefined);
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        reject(e);
      }
    });
    req.on("error", reject);
  });
}

function json(res: http.ServerResponse, status: number, body: unknown) {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
  });
  res.end(JSON.stringify(body));
}

function unauthorized(res: http.ServerResponse, detail: string) {
  // RFC 6750 §3 — WWW-Authenticate hints Claude Desktop (or any
  // OAuth-aware MCP client) at the resource-metadata URL so it can
  // discover the authorization server and start the OAuth dance.
  // The resource value must match the URL clients connect to.
  const metadata = `${publicUrl}/.well-known/oauth-protected-resource`;
  res.writeHead(401, {
    "Content-Type": "application/json",
    "WWW-Authenticate": `Bearer realm="wg0-mcp", resource_metadata="${metadata}"`,
  });
  res.end(JSON.stringify({ error: "unauthorized", detail }));
}

/**
 * Best-effort token introspection. Phase 1 accepts wg0_pat_ directly;
 * any other token shape is rejected with 401 so Claude's OAuth flow
 * gets a chance to kick in when Phase 2 is wired.
 */
function isAcceptableToken(token: string): boolean {
  return token.startsWith("wg0_pat_") || token.startsWith("wg0_mcp_");
}

async function handleMcp(req: http.IncomingMessage, res: http.ServerResponse) {
  const sessionIdHeader = req.headers["mcp-session-id"];
  const sessionId = Array.isArray(sessionIdHeader)
    ? sessionIdHeader[0]
    : sessionIdHeader;

  let session = sessionId ? sessions.get(sessionId) : undefined;

  // New session: validate bearer + create Server+Transport.
  if (!session) {
    const token = extractBearer(req);
    if (!token) {
      return unauthorized(
        res,
        "Missing Authorization header. Paste a wg0 PAT (wg0_pat_…) or complete the OAuth flow.",
      );
    }
    if (!isAcceptableToken(token)) {
      return unauthorized(
        res,
        "Token format not recognized. Expected wg0_pat_… or an OAuth-issued access token.",
      );
    }
    const client = new Wg0Client({ brainUrl, apiKey: token });
    const { server } = createMcpServer(client);

    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: () => randomUUID(),
      onsessioninitialized: (id) => {
        sessions.set(id, { server, transport, client, apiKey: token });
      },
    });
    transport.onclose = () => {
      const id = transport.sessionId;
      if (id) sessions.delete(id);
    };

    await server.connect(transport);
    session = { server, transport, client, apiKey: token };
  } else {
    // Claude and other OAuth-capable MCP clients may refresh the
    // bearer token without tearing down the MCP session. Honor a
    // rotated bearer here so the cached Wg0Client doesn't keep using
    // an expired access token for the lifetime of the session.
    const token = extractBearer(req);
    if (token) {
      if (!isAcceptableToken(token)) {
        return unauthorized(
          res,
          "Token format not recognized. Expected wg0_pat_… or an OAuth-issued access token.",
        );
      }
      if (token !== session.apiKey) {
        session.apiKey = token;
        session.client.setApiKey(token);
        process.stderr.write(
          `wg0-mcp-http: rotated bearer for session ${session.transport.sessionId ?? "pending"}\n`,
        );
      }
    }
  }

  let body: unknown = undefined;
  if (req.method === "POST") {
    try {
      body = await readBody(req);
    } catch (e) {
      return json(res, 400, { error: "invalid_json", detail: String(e) });
    }
  }
  await session.transport.handleRequest(req, res, body);
}

function handleWellKnown(
  req: http.IncomingMessage,
  res: http.ServerResponse,
  path: string,
) {
  const brainBase = process.env.WG0_AUTH_BASE_URL ?? "https://connect.wg0.io";
  // RFC 9728 — OAuth Protected Resource Metadata.
  if (path === "/.well-known/oauth-protected-resource") {
    return json(res, 200, {
      resource: publicUrl,
      authorization_servers: [brainBase],
      bearer_methods_supported: ["header"],
      resource_documentation: "https://wg0.io/MCP.md",
    });
  }
  // Claude Desktop also queries the AS metadata at the resource host
  // during discovery. Proxy it from the brain so clients don't have
  // to know the auth server URL separately.
  if (path === "/.well-known/oauth-authorization-server") {
    return json(res, 200, {
      issuer: brainBase,
      authorization_endpoint: `${brainBase}/oauth/authorize`,
      token_endpoint: `${brainBase}/oauth/token`,
      registration_endpoint: `${brainBase}/oauth/register`,
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none", "client_secret_basic"],
      scopes_supported: ["mcp"],
    });
  }
  json(res, 404, { error: "not_found" });
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? "/", "http://localhost");
    // CORS for browser-based clients / the Claude Desktop renderer.
    if (req.method === "OPTIONS") {
      res.writeHead(204, {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
        "Access-Control-Allow-Headers":
          "Authorization, Content-Type, Mcp-Session-Id, Mcp-Protocol-Version",
        "Access-Control-Expose-Headers":
          "Mcp-Session-Id, WWW-Authenticate",
        "Access-Control-Max-Age": "86400",
      });
      return res.end();
    }
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.setHeader(
      "Access-Control-Expose-Headers",
      "Mcp-Session-Id, WWW-Authenticate",
    );

    if (url.pathname === "/healthz") {
      return json(res, 200, { status: "ok", service: "wg0-mcp-http" });
    }
    if (url.pathname.startsWith("/.well-known/")) {
      return handleWellKnown(req, res, url.pathname);
    }
    if (url.pathname === "/mcp" || url.pathname === "/") {
      return await handleMcp(req, res);
    }
    return json(res, 404, { error: "not_found", path: url.pathname });
  } catch (e) {
    process.stderr.write(`wg0-mcp-http: request error: ${String(e)}\n`);
    if (!res.headersSent) {
      res.writeHead(500, { "Content-Type": "application/json" });
      res.end(JSON.stringify({ error: "internal", detail: String(e) }));
    }
  }
});

server.listen(port, () => {
  process.stderr.write(
    `wg0-mcp-http: listening on :${port} (brain=${brainUrl}, public=${publicUrl})\n`,
  );
});

process.on("SIGINT", () => {
  server.close();
  process.exit(0);
});
process.on("SIGTERM", () => {
  server.close();
  process.exit(0);
});
