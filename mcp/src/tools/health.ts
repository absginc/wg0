/**
 * Health check — useful for the agent to probe "is my brain reachable"
 * before trying anything else.
 */

import { z } from "zod";
import type { Wg0Client } from "../client.js";
import type { Tool } from "./types.js";

export function healthTools(client: Wg0Client): Tool[] {
  return [
    {
      name: "health_check",
      description:
        "Probe the wg0 brain for liveness. Returns { status: 'ok', service: 'wg0-brain' } on success. Use this as the first call in any workflow — if it fails, the brain is unreachable or the PAT is wrong.",
      inputSchema: z.object({}),
      handler: async () => client.get("/health"),
    },
  ];
}
