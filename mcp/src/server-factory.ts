/**
 * Factory that builds a fully-wired MCP Server for a given
 * per-request authenticated Wg0Client. Extracted so both the stdio
 * (single-process, one PAT) and Streamable HTTP (multi-tenant, bearer
 * per connection) transports can reuse the same tool/resource/prompt
 * wiring.
 */
import { Server } from "@modelcontextprotocol/sdk/server/index.js";
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
import { deviceTools } from "./tools/devices.js";
import { sharedNetworkTools } from "./tools/shared_networks.js";
import { siteAccessTools } from "./tools/site_access.js";

function zodToJsonSchema(schema: z.ZodTypeAny): any {
  const def = (schema as any)._def;
  const typeName = def?.typeName as string | undefined;
  if (typeName === "ZodObject") {
    const shape = def.shape();
    const properties: Record<string, any> = {};
    const required: string[] = [];
    for (const [key, value] of Object.entries(shape)) {
      const fieldSchema = value as z.ZodTypeAny;
      properties[key] = zodToJsonSchema(fieldSchema);
      if (!isOptional(fieldSchema)) required.push(key);
    }
    const out: any = { type: "object", properties };
    if (required.length > 0) out.required = required;
    return out;
  }
  if (typeName === "ZodString") {
    const out: any = { type: "string" };
    if (def.description) out.description = def.description;
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
  if (typeName === "ZodOptional") return zodToJsonSchema(def.innerType);
  if (typeName === "ZodDefault") {
    const inner = zodToJsonSchema(def.innerType);
    return { ...inner, default: def.defaultValue() };
  }
  return {};
}

function isOptional(schema: z.ZodTypeAny): boolean {
  const tn = (schema as any)._def?.typeName;
  return tn === "ZodOptional" || tn === "ZodDefault";
}

const STATIC_RESOURCES = [
  {
    uri: "wg0://docs/llms.txt",
    name: "wg0 llms.txt",
    description:
      "llmstxt.org-compliant agent index. Prioritized pointers to every canonical wg0 doc.",
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

const PROMPTS = [
  {
    name: "audit_networks",
    description:
      "Walk through every wg0 network the user owns, showing node counts, presence, and unusual state.",
    arguments: [],
    template:
      "Use list_networks to get every network, then list_nodes for each, and give me a concise report. Call out anything that looks unusual.",
  },
  {
    name: "provision_mobile_device",
    description:
      "Enroll a mobile device. Prefers the wg0 native app path (managed URI, device-generated keypair); falls back to the stock-WireGuard QR if the user can't install the wg0 app.",
    arguments: [
      { name: "network_name", description: "Name of the network.", required: true },
      { name: "device_name", description: "Friendly device name.", required: true },
      { name: "app_flavor", description: "'wg0-native' (default, preferred — uses Android alpha18+ / iOS tbd) or 'stock-wireguard' (for users on the App Store / Play Store WireGuard app with no wg0 install).", required: false },
    ],
    template:
      "I want to provision a new mobile device named {device_name} into the network {network_name} (app_flavor={app_flavor}, default 'wg0-native'). Use list_networks to find the network_id. For 'wg0-native': call generate_enrollment_token with that network_id, then show me the returned `managed_enroll_uri` so I can render it as a QR for the wg0 Android / iOS app to scan. For 'stock-wireguard': call provision_device with os_type matching the device + role='client' and return the wg_config text so I can pipe it into qrencode. Tell me which path was chosen + why. Do not use provision_device when the user has the wg0 native app — it embeds a private key the user doesn't need to handle.",
  },
  {
    name: "activate_byo_exit",
    description:
      "Activate an upstream BYO Exit on a host. Route-all clients inherit it on next heartbeat.",
    arguments: [
      { name: "host_name", description: "Node name of the host.", required: true },
      { name: "exit_name", description: "Friendly name of the upstream exit.", required: true },
    ],
    template:
      "Activate the upstream exit named '{exit_name}' on host '{host_name}'. Use list_nodes to find the host, list_upstream_exits for the exit, then activate_upstream_exit.",
  },
  {
    name: "roaming_investigation",
    description:
      "Investigate why a device's observed_endpoint keeps changing.",
    arguments: [
      { name: "device_name", description: "Node name to investigate.", required: true },
    ],
    template:
      "Look at the device named '{device_name}'. Get its row from list_nodes and summarize presence, observed_endpoint, last_endpoint, last_activity, device_kind, route_all_active. Say in plain English whether it looks healthy.",
  },
];

export interface FactoryResult {
  server: Server;
  toolCount: number;
  resourceCount: number;
  promptCount: number;
}

/**
 * Build a new MCP Server instance bound to this client. Each caller
 * (session) gets its own Server so tool handlers close over the
 * correct PAT/JWT.
 */
export function createMcpServer(client: Wg0Client): FactoryResult {
  const allTools: Tool[] = [
    ...healthTools(client),
    ...networkTools(client),
    ...nodeTools(client),
    ...deviceTools(client),
    ...sharedNetworkTools(client),
    ...siteAccessTools(client),
    ...enrollmentTools(client),
    ...byoExitTools(client),
    ...trafficTools(client),
  ];
  const toolsByName = new Map<string, Tool>();
  for (const t of allTools) toolsByName.set(t.name, t);

  const server = new Server(
    { name: "wg0-mcp-server", version: "0.2.0" },
    { capabilities: { tools: {}, resources: {}, prompts: {} } },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: allTools.map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: zodToJsonSchema(t.inputSchema),
    })),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req) => {
    const tool = toolsByName.get(req.params.name);
    if (!tool) {
      throw new McpError(
        ErrorCode.MethodNotFound,
        `Unknown tool: ${req.params.name}`,
      );
    }
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
      return { isError: true, content: [{ type: "text", text: message }] };
    }
  });

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
        { uri: match.uri, mimeType: match.mimeType, text },
      ],
    };
  });

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
    let text = match.template;
    const args = req.params.arguments ?? {};
    for (const [key, value] of Object.entries(args)) {
      text = text.replaceAll(`{${key}}`, String(value));
    }
    return {
      description: match.description,
      messages: [{ role: "user", content: { type: "text", text } }],
    };
  });

  return {
    server,
    toolCount: allTools.length,
    resourceCount: STATIC_RESOURCES.length,
    promptCount: PROMPTS.length,
  };
}
