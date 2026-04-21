import { z } from "zod";
import type { Wg0Client } from "../client.js";
import type { Tool } from "./types.js";

export function siteAccessTools(client: Wg0Client): Tool[] {
  return [
    {
      name: "list_gateway_exports",
      description:
        "List gateway exports for a hub_spoke access network.",
      inputSchema: z.object({
        access_network_id: z.string().uuid(),
      }),
      handler: async ({ access_network_id }) =>
        client.get(`/api/v1/networks/${access_network_id}/gateway-exports`),
    },
    {
      name: "create_gateway_export",
      description:
        "Create a site-access gateway export from a gateway node inside an access network.",
      inputSchema: z.object({
        access_network_id: z.string().uuid(),
        gateway_node_id: z.string().uuid(),
        source_network_id: z.string().uuid(),
        label: z.string(),
        exported_routes: z.array(z.string()).min(1),
        enabled: z.boolean().default(true),
        conflict_key: z.string().optional(),
      }),
      handler: async ({ access_network_id, ...body }) =>
        client.post(`/api/v1/networks/${access_network_id}/gateway-exports`, body),
    },
    {
      name: "update_gateway_export",
      description:
        "Update label, routes, enabled state, or conflict key on a gateway export.",
      inputSchema: z.object({
        gateway_export_id: z.string().uuid(),
        label: z.string().optional(),
        exported_routes: z.array(z.string()).optional(),
        enabled: z.boolean().optional(),
        conflict_key: z.string().optional(),
      }),
      handler: async ({ gateway_export_id, ...body }) =>
        client.patch(`/api/v1/gateway-exports/${gateway_export_id}`, body),
    },
    {
      name: "delete_gateway_export",
      description:
        "Delete a gateway export permanently.",
      inputSchema: z.object({
        gateway_export_id: z.string().uuid(),
      }),
      handler: async ({ gateway_export_id }) =>
        client.delete(`/api/v1/gateway-exports/${gateway_export_id}`),
    },
    {
      name: "list_access_grants",
      description:
        "List site-access grants for a hub_spoke access network.",
      inputSchema: z.object({
        access_network_id: z.string().uuid(),
      }),
      handler: async ({ access_network_id }) =>
        client.get(`/api/v1/networks/${access_network_id}/access-grants`),
    },
    {
      name: "create_access_grant",
      description:
        "Grant an exported site to a user, device_profile, or managed device.",
      inputSchema: z.object({
        access_network_id: z.string().uuid(),
        gateway_export_id: z.string().uuid(),
        subject_type: z.enum(["user", "device_profile", "device"]),
        subject_id: z.string().uuid(),
        active: z.boolean().default(true),
      }),
      handler: async ({ access_network_id, ...body }) =>
        client.post(`/api/v1/networks/${access_network_id}/access-grants`, body),
    },
    {
      name: "update_access_grant",
      description:
        "Activate or deactivate a site-access grant.",
      inputSchema: z.object({
        access_grant_id: z.string().uuid(),
        active: z.boolean(),
      }),
      handler: async ({ access_grant_id, active }) =>
        client.patch(`/api/v1/access-grants/${access_grant_id}`, { active }),
    },
    {
      name: "delete_access_grant",
      description:
        "Delete an access grant permanently.",
      inputSchema: z.object({
        access_grant_id: z.string().uuid(),
      }),
      handler: async ({ access_grant_id }) =>
        client.delete(`/api/v1/access-grants/${access_grant_id}`),
    },
  ];
}
