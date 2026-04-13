/**
 * BYO Exit Phase 1 tools. Upload a provider WireGuard config (Mullvad,
 * Proton, Azire, or custom), attach it to a host, activate/deactivate.
 * Route-all clients on that host inherit the upstream exit.
 */

import { z } from "zod";
import type { Wg0Client } from "../client.js";
import type { Tool } from "./types.js";

export function byoExitTools(client: Wg0Client): Tool[] {
  return [
    {
      name: "list_upstream_exits",
      description:
        "List upstream exits attached to a host. The wg_config field is intentionally excluded — it contains a private key and only the host itself should ever see it (via its heartbeat).",
      inputSchema: z.object({
        host_node_id: z.string().uuid(),
      }),
      handler: async ({ host_node_id }) =>
        client.get(`/api/v1/nodes/${host_node_id}/upstream-exits`),
    },
    {
      name: "create_upstream_exit",
      description:
        "Upload a provider WireGuard config and attach it to a host. The host must be role=host in a native-LAN network. Passing the full wg0.conf text is required (usually starts with '[Interface]\\nPrivateKey = ...'). Once uploaded, activate it with update_node + current_upstream_exit_id.",
      inputSchema: z.object({
        host_node_id: z.string().uuid(),
        name: z.string().describe("Friendly label, e.g. 'Mullvad SE'."),
        provider_type: z
          .string()
          .default("custom-wg")
          .describe(
            "One of 'mullvad', 'proton', 'azire', 'custom-wg'. Used only for UI classification.",
          ),
        wg_config: z
          .string()
          .describe(
            "Full wg0.conf text as downloaded from the provider, including the PrivateKey line.",
          ),
      }),
      handler: async ({ host_node_id, ...body }) =>
        client.post(`/api/v1/nodes/${host_node_id}/upstream-exits`, body),
    },
    {
      name: "delete_upstream_exit",
      description:
        "Delete an upstream exit permanently. If it was the host's active exit, the host's next heartbeat will tear down the upstream tunnel and revert to the physical WAN.",
      inputSchema: z.object({
        upstream_exit_id: z.string().uuid(),
      }),
      handler: async ({ upstream_exit_id }) =>
        client.delete(`/api/v1/upstream-exits/${upstream_exit_id}`),
    },
    {
      name: "activate_upstream_exit",
      description:
        "Activate an upstream exit on its host. Thin wrapper around update_node that sets current_upstream_exit_id.",
      inputSchema: z.object({
        host_node_id: z.string().uuid(),
        upstream_exit_id: z.string().uuid(),
      }),
      handler: async ({ host_node_id, upstream_exit_id }) =>
        client.patch(`/api/v1/nodes/${host_node_id}`, {
          current_upstream_exit_id: upstream_exit_id,
        }),
    },
    {
      name: "deactivate_upstream_exit",
      description:
        "Clear the host's active upstream exit. The host's next heartbeat tears down wg0-up and reverts to the physical WAN.",
      inputSchema: z.object({
        host_node_id: z.string().uuid(),
      }),
      handler: async ({ host_node_id }) =>
        client.patch(`/api/v1/nodes/${host_node_id}`, {
          clear_upstream_exit: true,
        }),
    },
  ];
}
