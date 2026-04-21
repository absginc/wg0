import { z } from "zod";
import type { Wg0Client } from "../client.js";
import type { Tool } from "./types.js";

export function sharedNetworkTools(client: Wg0Client): Tool[] {
  return [
    {
      name: "list_shared_network_access",
      description:
        "List pending shared invites and active shared members for a network.",
      inputSchema: z.object({
        network_id: z.string().uuid(),
      }),
      handler: async ({ network_id }) =>
        client.get(`/api/v1/networks/${network_id}/shared-access`),
    },
    {
      name: "create_shared_network_invite",
      description:
        "Email a shared-network invite to a recipient. If they do not already have a wg0 account, a free account is created when they accept.",
      inputSchema: z.object({
        network_id: z.string().uuid(),
        email: z.string().email(),
        access_mode: z.enum(["network_member", "routed_only"]).default("network_member"),
      }),
      handler: async ({ network_id, ...body }) =>
        client.post(`/api/v1/networks/${network_id}/shared-invites`, body),
    },
    {
      name: "revoke_shared_network_invite",
      description:
        "Delete a pending shared-network invitation that has not been accepted yet.",
      inputSchema: z.object({
        invitation_id: z.string().uuid(),
      }),
      handler: async ({ invitation_id }) =>
        client.delete(`/api/v1/shared-network-invitations/${invitation_id}`),
    },
    {
      name: "revoke_shared_network_member",
      description:
        "Revoke a shared-network member entirely. Their active shared nodes are deactivated and pending shared attaches are cancelled.",
      inputSchema: z.object({
        membership_id: z.string().uuid(),
      }),
      handler: async ({ membership_id }) =>
        client.delete(`/api/v1/shared-network-memberships/${membership_id}`),
    },
    {
      name: "revoke_shared_network_device",
      description:
        "Revoke one active shared device from a shared-network member without removing the rest of their shared access.",
      inputSchema: z.object({
        membership_id: z.string().uuid(),
        node_id: z.string().uuid(),
      }),
      handler: async ({ membership_id, node_id }) =>
        client.delete(`/api/v1/shared-network-memberships/${membership_id}/nodes/${node_id}`),
    },
    {
      name: "preflight_shared_network_attach",
      description:
        "Check whether a recipient can attach one of their existing managed devices to a shared network without conflicting routes.",
      inputSchema: z.object({
        membership_id: z.string().uuid(),
        device_id: z.string().uuid(),
      }),
      handler: async ({ membership_id, device_id }) =>
        client.post(`/api/v1/shared-network-memberships/${membership_id}/attach-preflight`, {
          device_id,
        }),
    },
    {
      name: "attach_device_to_shared_network",
      description:
        "Queue a shared-network attach request for one of the recipient's existing managed devices.",
      inputSchema: z.object({
        membership_id: z.string().uuid(),
        device_id: z.string().uuid(),
      }),
      handler: async ({ membership_id, device_id }) =>
        client.post(`/api/v1/shared-network-memberships/${membership_id}/attach`, {
          device_id,
        }),
    },
    {
      name: "generate_shared_network_enrollment_token",
      description:
        "Mint a shared-network enrollment token so the recipient can enroll a new managed connector into the shared network.",
      inputSchema: z.object({
        membership_id: z.string().uuid(),
        node_name: z.string().optional(),
      }),
      handler: async ({ membership_id, node_name }) =>
        client.post(`/api/v1/shared-networks/${membership_id}/enroll-token`, {
          node_name,
        }),
    },
  ];
}
