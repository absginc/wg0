#!/usr/bin/env node
/**
 * wg0 MCP server — entry point.
 *
 * Two transports:
 *   - stdio (default): spawned by the agent host as a subprocess, one
 *     PAT per process via WG0_API_KEY env. Drop-in for
 *     claude_desktop_config.json.
 *   - streamable-http: long-running HTTP server with per-request
 *     bearer auth. Enabled by WG0_MCP_MODE=http (or WG0_MCP_MODE=sse
 *     for the same thing under the old name).
 *
 * Both transports share the same Server factory in server-factory.ts.
 */

export {};

const mode = (process.env.WG0_MCP_MODE ?? "stdio").toLowerCase();

if (mode === "http" || mode === "streamable-http" || mode === "sse") {
  // Long-running HTTP transport. Spins up http.createServer() and
  // keeps the event loop alive on its own.
  await import("./http-server.js");
} else {
  // stdio — the original single-tenant mode.
  const { StdioServerTransport } = await import(
    "@modelcontextprotocol/sdk/server/stdio.js"
  );
  const { Wg0Client } = await import("./client.js");
  const { createMcpServer } = await import("./server-factory.js");

  const brainUrl = process.env.WG0_BRAIN_URL ?? "https://connect.wg0.io";
  const apiKey = process.env.WG0_API_KEY ?? "";
  if (!apiKey) {
    process.stderr.write(
      "wg0-mcp: WG0_API_KEY is required. Mint a PAT via POST /api/v1/api-keys and set it in your agent config.\n",
    );
    process.exit(1);
  }
  if (!apiKey.startsWith("wg0_pat_")) {
    process.stderr.write(
      "wg0-mcp: WG0_API_KEY must start with 'wg0_pat_'. JWTs are not supported.\n",
    );
    process.exit(1);
  }
  const client = new Wg0Client({ brainUrl, apiKey });
  const { server, toolCount, resourceCount, promptCount } =
    createMcpServer(client);
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write(
    `wg0-mcp: ready. brain=${brainUrl}, tools=${toolCount}, resources=${resourceCount}, prompts=${promptCount}\n`,
  );
}
