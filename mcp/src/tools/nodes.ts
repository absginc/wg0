/**
 * Node-level tools.
 *
 * Most of the interesting workflows live here: listing nodes with
 * four-state presence, flipping route-all, swapping upstream exits,
 * provisioning mobile devices via server-side keygen.
 */

import { z } from "zod";
import type { Wg0Client } from "../client.js";
import type { Tool } from "./types.js";

export function nodeTools(client: Wg0Client): Tool[] {
  return [
    {
      name: "list_nodes",
      description:
        "List nodes owned by the authenticated account. Returns an array with derived fields per node: presence (online/observed/offline/unknown), observed_endpoint (real post-NAT address from the discover sidecar), last_activity (max of heartbeat + observations — the truthful 'last seen' field, not the stored last_seen which can be stale for mobile peers), on_host_lan, device_kind (managed vs provisioned), and route_all_active. Accepts an optional network_id filter.",
      inputSchema: z.object({
        network_id: z.string().uuid().optional(),
      }),
      handler: async ({ network_id }) => {
        const qs = network_id ? `?network_id=${network_id}` : "";
        return client.get(`/api/v1/nodes${qs}`);
      },
    },
    {
      name: "update_node",
      description:
        "Update per-node settings. Use this to toggle route_all_traffic on a native-LAN client (turns the host into a full VPN exit for that client), activate/clear a BYO Exit on a host, or rename a node. The brain bumps config_version on any field that affects the rendered wg_config, and the managed connector will fetch fresh config on its next heartbeat (~30s).",
      inputSchema: z.object({
        node_id: z.string().uuid(),
        node_name: z.string().optional(),
        route_all_traffic: z
          .boolean()
          .optional()
          .describe(
            "Only valid on client nodes in native-LAN networks. Turning on forces the host to become a full VPN exit for this client.",
          ),
        current_upstream_exit_id: z
          .string()
          .uuid()
          .optional()
          .describe(
            "Only valid on host nodes in native-LAN networks. Activates an upstream exit previously uploaded via list_upstream_exits / create_upstream_exit.",
          ),
        clear_upstream_exit: z
          .boolean()
          .optional()
          .describe(
            "Only valid on host nodes. True clears the host's active upstream exit — internet traffic falls back to the physical WAN.",
          ),
      }),
      handler: async ({ node_id, ...patch }) =>
        client.patch(`/api/v1/nodes/${node_id}`, patch),
    },
    {
      name: "delete_node",
      description:
        "Remove a node. The brain unregisters it from the discover sidecar on delete. Use cautiously — if the node was the native-LAN host, its clients lose tunnel access until they re-enroll into a new host.",
      inputSchema: z.object({
        node_id: z.string().uuid(),
      }),
      handler: async ({ node_id }) =>
        client.delete(`/api/v1/nodes/${node_id}`),
    },
    {
      name: "provision_device",
      description:
        "Server-side keygen + enroll for a mobile / QR-flow device. The brain generates a WireGuard keypair, enrolls a new node as device_kind='provisioned', and returns the full wg_config text with the PrivateKey line already populated. The dashboard renders this as a QR code for stock WireGuard mobile apps. The private key is returned ONCE and never persisted.",
      inputSchema: z.object({
        network_id: z.string().uuid(),
        node_name: z.string(),
        os_type: z
          .string()
          .optional()
          .describe("e.g. 'ios', 'android' — used for UI classification."),
        role: z
          .enum(["client", "host"])
          .default("client")
          .describe("Usually 'client' for mobile devices."),
        advertised_routes: z
          .array(z.string())
          .optional()
          .describe("Optional static LAN subnets to advertise. Rare for mobile."),
      }),
      handler: async ({ network_id, ...body }) =>
        client.post(`/api/v1/networks/${network_id}/provision`, body),
    },
  ];
}
