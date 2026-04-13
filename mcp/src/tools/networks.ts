/**
 * Network-level tools.
 *
 * Agents use these to audit what mesh networks exist, create a new
 * one, or destroy an existing one. `list_networks` is the canonical
 * first call for almost any wg0 workflow — most other operations
 * need a network_id.
 */

import { z } from "zod";
import type { Wg0Client } from "../client.js";
import type { Tool } from "./types.js";

export function networkTools(client: Wg0Client): Tool[] {
  return [
    {
      name: "list_networks",
      description:
        "List every wg0 network owned by the authenticated account. Returns an array of networks enriched with aggregate counts: node_count, online_count (Online + Observed), tx_bytes, rx_bytes. This is the canonical first call — most other operations need a network_id from this response.",
      inputSchema: z.object({}),
      handler: async () => client.get("/api/v1/networks"),
    },
    {
      name: "create_network",
      description:
        "Create a new network. Two kinds: 'overlay' (private subnet like 10.64.x.x, auto-assigned if omitted) or 'native' (clients appear as real members of a host's existing LAN like 192.168.1.0/24). Native networks require the native_* fields describing the host LAN layout.",
      inputSchema: z.object({
        name: z.string().describe("Human-friendly name for the network."),
        network_type: z
          .enum(["overlay", "native"])
          .default("overlay")
          .describe("Placement type."),
        overlay_subnet: z
          .string()
          .optional()
          .describe(
            "Overlay mode only. CIDR subnet like '10.64.5.0/24'. Omit to auto-assign.",
          ),
        native_gateway_subnet: z
          .string()
          .optional()
          .describe(
            "Native mode only. The host LAN subnet, e.g. '192.168.1.0/24'.",
          ),
        native_host_tunnel_ip: z
          .string()
          .optional()
          .describe(
            "Native mode only. The IP the host's wg0 interface binds inside the LAN, e.g. '192.168.1.2'.",
          ),
        native_client_start: z
          .string()
          .optional()
          .describe("Native mode only. First IP in the client pool."),
        native_client_end: z
          .string()
          .optional()
          .describe("Native mode only. Last IP in the client pool."),
      }),
      handler: async (args) => client.post("/api/v1/networks", args),
    },
    {
      name: "delete_network",
      description:
        "Delete a network and every node inside it. Destructive — no confirmation, no undo. Use list_networks first to confirm the id.",
      inputSchema: z.object({
        network_id: z.string().uuid(),
      }),
      handler: async ({ network_id }) =>
        client.delete(`/api/v1/networks/${network_id}`),
    },
  ];
}
