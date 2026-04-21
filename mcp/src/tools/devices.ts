import { z } from "zod";
import type { Wg0Client } from "../client.js";
import type { Tool } from "./types.js";

export function deviceTools(client: Wg0Client): Tool[] {
  return [
    {
      name: "list_devices",
      description:
        "List managed installations visible to the caller. This is the device-first surface: devices own memberships, pending attach requests, telemetry, and installation capabilities.",
      inputSchema: z.object({}),
      handler: async () => client.get("/api/v1/devices"),
    },
    {
      name: "get_device",
      description:
        "Fetch one managed device with memberships and pending attach requests.",
      inputSchema: z.object({
        device_id: z.string().uuid(),
      }),
      handler: async ({ device_id }) => client.get(`/api/v1/devices/${device_id}`),
    },
    {
      name: "update_device",
      description:
        "Update a managed device's display_name and/or collect_device_telemetry setting.",
      inputSchema: z.object({
        device_id: z.string().uuid(),
        display_name: z.string().optional(),
        collect_device_telemetry: z.boolean().optional(),
      }),
      handler: async ({ device_id, ...body }) =>
        client.patch(`/api/v1/devices/${device_id}`, body),
    },
    {
      name: "delete_device",
      description:
        "Delete a managed device installation and every membership attached to it. Destructive.",
      inputSchema: z.object({
        device_id: z.string().uuid(),
      }),
      handler: async ({ device_id }) => client.delete(`/api/v1/devices/${device_id}`),
    },
    {
      name: "get_device_endpoint_history",
      description:
        "Return endpoint history entries across all memberships of a managed device.",
      inputSchema: z.object({
        device_id: z.string().uuid(),
        limit: z.number().int().min(1).max(1000).default(500),
      }),
      handler: async ({ device_id, limit }) =>
        client.get(`/api/v1/devices/${device_id}/endpoint-history?limit=${limit}`),
    },
    {
      name: "get_device_peerings",
      description:
        "Return peering and relay-helper state grouped by membership for a managed device.",
      inputSchema: z.object({
        device_id: z.string().uuid(),
      }),
      handler: async ({ device_id }) =>
        client.get(`/api/v1/devices/${device_id}/peerings`),
    },
    {
      name: "preflight_device_attach",
      description:
        "Check whether attaching another network to a managed device would conflict with active routes or runtime capabilities.",
      inputSchema: z.object({
        device_id: z.string().uuid(),
        network_id: z.string().uuid(),
        desired_role: z.enum(["client", "host"]).default("client"),
      }),
      handler: async ({ device_id, ...body }) =>
        client.post(`/api/v1/devices/${device_id}/memberships/preflight`, body),
    },
    {
      name: "attach_device_to_network",
      description:
        "Queue a new membership attach request for a managed device. The runtime must fulfill it on the next installation heartbeat.",
      inputSchema: z.object({
        device_id: z.string().uuid(),
        network_id: z.string().uuid(),
        desired_role: z.enum(["client", "host"]).default("client"),
        desired_name: z.string().optional(),
        desired_advertised_routes: z.array(z.string()).optional(),
      }),
      handler: async ({ device_id, ...body }) =>
        client.post(`/api/v1/devices/${device_id}/memberships`, body),
    },
    {
      name: "update_device_membership",
      description:
        "Update one active membership on a managed device: rename it, change role, adjust advertised routes, host fields, or route_all_traffic.",
      inputSchema: z.object({
        device_id: z.string().uuid(),
        node_id: z.string().uuid(),
        node_name: z.string().optional(),
        role: z.enum(["client", "host"]).optional(),
        advertised_routes: z.array(z.string()).optional(),
        host_priority: z.number().int().optional(),
        host_lan_ip: z.string().optional(),
        route_all_traffic: z.boolean().optional(),
      }),
      handler: async ({ device_id, node_id, ...body }) =>
        client.patch(`/api/v1/devices/${device_id}/memberships/${node_id}`, body),
    },
    {
      name: "remove_device_membership",
      description:
        "Remove one active membership from a managed device without deleting the whole device installation.",
      inputSchema: z.object({
        device_id: z.string().uuid(),
        node_id: z.string().uuid(),
      }),
      handler: async ({ device_id, node_id }) =>
        client.delete(`/api/v1/devices/${device_id}/memberships/${node_id}`),
    },
  ];
}
