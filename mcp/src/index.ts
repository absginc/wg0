#!/usr/bin/env node
/**
 * wg0 MCP server — exposes the wg0 brain's API as MCP tools so any
 * MCP-aware agent (Claude Desktop, Claude Code, Cursor, custom agents)
 * can operate a wg0 control plane conversationally.
 *
 * Transport: stdio. The binary is designed to be spawned by the agent
 * host (e.g. Claude Desktop via claude_desktop_config.json) with env
 * vars for the brain URL + PAT.
 *
 * Authentication: a personal access token (wg0_pat_...) minted from
 * `POST /api/v1/api-keys`. PATs authenticate as the owning account for
 * every brain endpoint except PAT management itself (mint requires a
 * real JWT). See docs/DEVICE_PROTOCOL.md and docs/ROADBLOCKS.md §9.
 *
 * Environment:
 *   WG0_BRAIN_URL  (default: https://connect.wg0.io)
 *   WG0_API_KEY    (required; must start with wg0_pat_)
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ErrorCode,
  ListPromptsRequestSchema,
  ListResourcesRequestSchema,
  ListToolsRequestSchema,
  McpError,
  ReadResourceRequestSchema,
  GetPromptRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";

import { Wg0Client, Wg0Error } from "./client.js";
import type { Tool } from "./tools/types.js";
import { networkTools } from "./tools/networks.js";
import { nodeTools } from "./tools/nodes.js";
import { enrollmentTools } from "./tools/enrollment.js";
import { byoExitTools } from "./tools/byo_exit.js";
import { trafficTools } from "./tools/traffic.js";
import { healthTools } from "./tools/health.js";

// ── Config validation ──────────────────────────────────────────────────────

const DEFAULT_BRAIN = "https://connect.wg0.io";
const brainUrl = process.env.WG0_BRAIN_URL ?? DEFAULT_BRAIN;
const apiKey = process.env.WG0_API_KEY ?? "";

if (!apiKey) {
  // Print to stderr — stdout is the MCP transport, writing there
  // would corrupt the JSON-RPC stream.
  process.stderr.write(
    "wg0-mcp: WG0_API_KEY is required. Mint a PAT via POST /api/v1/api-keys (see https://wg0.io/API.md) and set it in your agent config.\n",
  );
  process.exit(1);
}
if (!apiKey.startsWith("wg0_pat_")) {
  process.stderr.write(
    "wg0-mcp: WG0_API_KEY must start with 'wg0_pat_'. JWTs are not supported (they expire too quickly for long-running agents).\n",
  );
  process.exit(1);
}

// ── Client + tool registry ─────────────────────────────────────────────────

const client = new Wg0Client({ brainUrl, apiKey });

const allTools: Tool[] = [
  ...healthTools(client),
  ...networkTools(client),
  ...nodeTools(client),
  ...enrollmentTools(client),
  ...byoExitTools(client),
  ...trafficTools(client),
];

const toolsByName = new Map<string, Tool>();
for (const t of allTools) {
  toolsByName.set(t.name, t);
}

// ── Zod → JSON Schema (minimal, what MCP needs) ────────────────────────────
//
// The MCP SDK doesn't ship a zod-to-json-schema converter, so we do a
// small walk of our own covering only the shapes we actually use in
// tool inputs (ZodObject with string/number/boolean/array/enum fields
// plus optional + default + describe). If we ever need richer schemas
// we can pull in `zod-to-json-schema` as a dep.

function zodToJsonSchema(schema: z.ZodTypeAny): any {
  const def = (schema as any)._def;
  const typeName = def?.typeName as string | undefined;

  if (typeName === "ZodObject") {
    const shape = def.shape();
    const properties: Record<string, any> = {};
    const required: string[] = [];
    for (const [key, value] of Object.entries(shape)) {
      const fieldSchema = value as z.ZodTypeAny;
      const rendered = zodToJsonSchema(fieldSchema);
      properties[key] = rendered;
      if (!isOptional(fieldSchema)) {
        required.push(key);
      }
    }
    const out: any = { type: "object", properties };
    if (required.length > 0) out.required = required;
    return out;
  }

  if (typeName === "ZodString") {
    const out: any = { type: "string" };
    if (def.description) out.description = def.description;
    // format: uuid / datetime / email are encoded via checks
    for (const check of def.checks ?? []) {
      if (check.kind === "uuid") out.format = "uuid";
      if (check.kind === "datetime") out.format = "date-time";
      if (check.kind === "email") out.format = "email";
    }
    return out;
  }

  if (typeName === "ZodNumber") {
    const out: any = { type: "number" };
    if (def.description) out.description = def.description;
    for (const check of def.checks ?? []) {
      if (check.kind === "int") out.type = "integer";
      if (check.kind === "min") out.minimum = check.value;
      if (check.kind === "max") out.maximum = check.value;
    }
    return out;
  }

  if (typeName === "ZodBoolean") {
    const out: any = { type: "boolean" };
    if (def.description) out.description = def.description;
    return out;
  }

  if (typeName === "ZodEnum") {
    return {
      type: "string",
      enum: def.values,
      ...(def.description ? { description: def.description } : {}),
    };
  }

  if (typeName === "ZodArray") {
    return {
      type: "array",
      items: zodToJsonSchema(def.type),
      ...(def.description ? { description: def.description } : {}),
    };
  }

  if (typeName === "ZodOptional") {
    return zodToJsonSchema(def.innerType);
  }

  if (typeName === "ZodDefault") {
    const inner = zodToJsonSchema(def.innerType);
    // ZodDefault wraps optional semantics — the key is not required
    // and has a default value. Most MCP clients don't honor JSON
    // Schema defaults in tool calls, but including them is harmless.
    const defaultValue = def.defaultValue();
    return { ...inner, default: defaultValue };
  }

  // Fallback: describe as any
  return {};
}

function isOptional(schema: z.ZodTypeAny): boolean {
  const tn = (schema as any)._def?.typeName;
  return tn === "ZodOptional" || tn === "ZodDefault";
}

// ── MCP server wiring ──────────────────────────────────────────────────────

const server = new Server(
  {
    name: "wg0-mcp-server",
    version: "0.1.0",
  },
  {
    capabilities: {
      tools: {},
      resources: {},
      prompts: {},
    },
  },
);

// Tool listing.
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: allTools.map((t) => ({
    name: t.name,
    description: t.description,
    inputSchema: zodToJsonSchema(t.inputSchema),
  })),
}));

// Tool dispatch.
server.setRequestHandler(CallToolRequestSchema, async (req) => {
  const tool = toolsByName.get(req.params.name);
  if (!tool) {
    throw new McpError(
      ErrorCode.MethodNotFound,
      `Unknown tool: ${req.params.name}`,
    );
  }

  // Validate args against the zod schema. On failure, return a
  // readable error to the agent.
  const parseResult = tool.inputSchema.safeParse(req.params.arguments ?? {});
  if (!parseResult.success) {
    return {
      isError: true,
      content: [
        {
          type: "text",
          text:
            `Invalid arguments for ${tool.name}:\n` +
            parseResult.error.errors
              .map((e) => `  - ${e.path.join(".")}: ${e.message}`)
              .join("\n"),
        },
      ],
    };
  }

  try {
    const result = await tool.handler(parseResult.data);
    return {
      content: [
        {
          type: "text",
          text:
            typeof result === "string"
              ? result
              : JSON.stringify(result, null, 2),
        },
      ],
    };
  } catch (err) {
    // Brain errors get surfaced as tool errors (visible to the
    // agent) rather than JSON-RPC errors (which Claude Desktop may
    // hide). This gives the agent a chance to retry or explain.
    const message =
      err instanceof Wg0Error
        ? `${err.message}${
            err.body && typeof err.body === "object"
              ? `\n\n${JSON.stringify(err.body, null, 2)}`
              : ""
          }`
        : err instanceof Error
          ? err.message
          : String(err);
    return {
      isError: true,
      content: [{ type: "text", text: message }],
    };
  }
});

// ── Resources ──────────────────────────────────────────────────────────────
//
// Expose a minimal set of read-only resources so agents can read wg0
// documentation directly. These are the same URLs served by the start
// container at https://wg0.io — but exposing them as MCP resources
// lets the agent load them on-demand without a user prompt.

const STATIC_RESOURCES = [
  {
    uri: "wg0://docs/llms.txt",
    name: "wg0 llms.txt",
    description:
      "llmstxt.org-compliant agent index. Prioritized pointers to every canonical wg0 doc (README, DEVICE_PROTOCOL, BYO_EXIT, TESTING_ROADMAP, CHANGELOG, ROADBLOCKS, MARKETING_TAILORS, API.md, openapi.yaml). Start here.",
    mimeType: "text/plain",
    upstream: "https://wg0.io/llms.txt",
  },
  {
    uri: "wg0://docs/openapi.yaml",
    name: "wg0 OpenAPI 3.1 spec",
    description:
      "Full machine-readable API spec. Use to understand endpoint shapes beyond what this MCP server exposes as tools.",
    mimeType: "application/yaml",
    upstream: "https://wg0.io/openapi.yaml",
  },
  {
    uri: "wg0://docs/API.md",
    name: "wg0 API guide",
    description:
      "Humans-first API reference with endpoint map, auth cheat sheet, and task recipes.",
    mimeType: "text/markdown",
    upstream: "https://wg0.io/API.md",
  },
];

server.setRequestHandler(ListResourcesRequestSchema, async () => ({
  resources: STATIC_RESOURCES.map((r) => ({
    uri: r.uri,
    name: r.name,
    description: r.description,
    mimeType: r.mimeType,
  })),
}));

server.setRequestHandler(ReadResourceRequestSchema, async (req) => {
  const match = STATIC_RESOURCES.find((r) => r.uri === req.params.uri);
  if (!match) {
    throw new McpError(
      ErrorCode.InvalidRequest,
      `Unknown resource URI: ${req.params.uri}`,
    );
  }
  // Resources fetch from the public wg0.io path rather than the
  // brain URL — they're product-level docs, not per-account data.
  const resp = await fetch(match.upstream);
  if (!resp.ok) {
    throw new McpError(
      ErrorCode.InternalError,
      `Failed to fetch ${match.upstream}: HTTP ${resp.status}`,
    );
  }
  const text = await resp.text();
  return {
    contents: [
      {
        uri: match.uri,
        mimeType: match.mimeType,
        text,
      },
    ],
  };
});

// ── Prompts ────────────────────────────────────────────────────────────────
//
// MCP prompts are named starter prompts the host can surface in its
// UI (e.g. Claude Desktop's command palette). They're useful for
// guiding the agent through common wg0 workflows without the user
// having to type the whole instruction.

const PROMPTS = [
  {
    name: "audit_networks",
    description:
      "Walk through every wg0 network the user owns, showing node counts, presence distribution, and any peers that look wrong (provisioned devices stuck on Unknown, managed devices Offline for > 1 day, etc).",
    arguments: [],
    template:
      "Use list_networks to get every network, then list_nodes for each, and give me a concise report. Call out anything that looks unusual: managed devices in Offline state, provisioned devices that are Unknown (never seen a handshake), or networks with zero online devices.",
  },
  {
    name: "provision_mobile_device",
    description:
      "Server-side keygen + enroll a mobile device for a network, then render the resulting wg_config as a QR code the user can scan.",
    arguments: [
      {
        name: "network_name",
        description:
          "Name of the network to provision into (e.g. 'home-native').",
        required: true,
      },
      {
        name: "device_name",
        description: "Friendly name for the new device (e.g. 'Pixel9XL').",
        required: true,
      },
    ],
    template:
      "I want to provision a new mobile device named {device_name} into the network {network_name}. Use list_networks to find the network_id, then call provision_device with os_type='android' (or 'ios' if appropriate) and role='client'. Return the wg_config text in a code block so I can pipe it into qrencode — do NOT store the private key anywhere; it's already in the config.",
  },
  {
    name: "activate_byo_exit",
    description:
      "Activate an upstream BYO Exit tunnel on a host node. Clients configured with route-all will inherit the upstream on their next heartbeat.",
    arguments: [
      {
        name: "host_name",
        description: "Node name of the host (e.g. 'home-host').",
        required: true,
      },
      {
        name: "exit_name",
        description:
          "Friendly name of the upstream exit (e.g. 'Mullvad SE'). Must already be uploaded via create_upstream_exit.",
        required: true,
      },
    ],
    template:
      "Activate the upstream exit named '{exit_name}' on host '{host_name}'. Use list_nodes to find the host by name, list_upstream_exits to find the exit by name, then activate_upstream_exit. Confirm the result.",
  },
  {
    name: "roaming_investigation",
    description:
      "Investigate why a specific device's observed_endpoint keeps changing — typical diagnostic workflow for mobile devices roaming between carriers.",
    arguments: [
      {
        name: "device_name",
        description: "Node name to investigate.",
        required: true,
      },
    ],
    template:
      "Look at the device named '{device_name}'. Get its full row from list_nodes and show me: presence, observed_endpoint, last_endpoint, last_activity, device_kind, and route_all_active. Explain in plain English whether the device looks healthy or not, and whether anything suggests it's been roaming (observed_endpoint from a different AS than last_endpoint, presence flapping, etc).",
  },
];

server.setRequestHandler(ListPromptsRequestSchema, async () => ({
  prompts: PROMPTS.map((p) => ({
    name: p.name,
    description: p.description,
    arguments: p.arguments,
  })),
}));

server.setRequestHandler(GetPromptRequestSchema, async (req) => {
  const match = PROMPTS.find((p) => p.name === req.params.name);
  if (!match) {
    throw new McpError(
      ErrorCode.InvalidRequest,
      `Unknown prompt: ${req.params.name}`,
    );
  }
  // Fill in {argument} placeholders from the request args.
  let text = match.template;
  const args = req.params.arguments ?? {};
  for (const [key, value] of Object.entries(args)) {
    text = text.replaceAll(`{${key}}`, String(value));
  }
  return {
    description: match.description,
    messages: [
      {
        role: "user",
        content: { type: "text", text },
      },
    ],
  };
});

// ── Boot ───────────────────────────────────────────────────────────────────

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // Boot banner goes to stderr so it doesn't contaminate the stdio
  // JSON-RPC stream.
  process.stderr.write(
    `wg0-mcp: ready. brain=${brainUrl}, tools=${allTools.length}, resources=${STATIC_RESOURCES.length}, prompts=${PROMPTS.length}\n`,
  );
}

main().catch((err) => {
  process.stderr.write(`wg0-mcp: fatal error: ${err}\n`);
  process.exit(1);
});
