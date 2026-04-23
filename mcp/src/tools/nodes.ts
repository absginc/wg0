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
      handler: async ({ node_id }) => {
        // Brain returns 204 with no body on success. The MCP runtime
        // can't encode `undefined` into a content block, so wrap the
        // outcome in a concrete object — otherwise callers see a
        // cosmetic "response-parsing" error on success.
        await client.delete(`/api/v1/nodes/${node_id}`);
        return {
          deleted: true,
          node_id,
          status: "Node removed. Its entry is gone from the brain; any peers that had it in their AllowedIPs will refresh on their next heartbeat.",
        };
      },
    },
    {
      name: "provision_device",
      description:
        "Server-side keygen + enroll for a stock-WireGuard-compatible mobile QR. The brain generates a WireGuard keypair, enrolls a node as device_kind='provisioned', and returns the full wg_config text with the PrivateKey line populated — render that as a QR for the stock WireGuard app (Android/iOS App Store) to consume. The private key is returned ONCE and never persisted. IMPORTANT: do NOT use this for the wg0 native apps. The wg0 Android native app (alpha18+) and future wg0 iOS app expect a `wg0://enroll?token=…&base=…` URI — mint one via `generate_enrollment_token` and render the returned `managed_enroll_uri` as a QR. The wg0 native path is preferred because the device generates its own keypair locally and no private key crosses the wire.",
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
