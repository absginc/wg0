/**
 * Traffic time-series tools. Both wrap existing brain endpoints that
 * return hourly buckets for the last N hours (defaults to 24).
 *
 * Provisioned devices will return an empty bucket array since they
 * don't report traffic — see `list_nodes` for the device_kind field.
 */

import { z } from "zod";
import type { Wg0Client } from "../client.js";
import type { Tool } from "./types.js";

export function trafficTools(client: Wg0Client): Tool[] {
  return [
    {
      name: "get_node_traffic",
      description:
        "Hourly TX/RX buckets for a single node over the last N hours. Empty bucket array is returned for provisioned peers (they don't run a heartbeat agent — use list_nodes to distinguish managed vs provisioned).",
      inputSchema: z.object({
        node_id: z.string().uuid(),
        hours: z.number().int().min(1).max(168).default(24),
      }),
      handler: async ({ node_id, hours }) =>
        client.get(`/api/v1/nodes/${node_id}/traffic?hours=${hours}`),
    },
    {
      name: "get_network_traffic",
      description:
        "Aggregated hourly TX/RX buckets for an entire network. Sums across managed nodes only.",
      inputSchema: z.object({
        network_id: z.string().uuid(),
        hours: z.number().int().min(1).max(168).default(24),
      }),
      handler: async ({ network_id, hours }) =>
        client.get(`/api/v1/networks/${network_id}/traffic?hours=${hours}`),
    },
  ];
}
