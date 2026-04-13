/**
 * Enrollment token tools. For enrolling a device that supplies its own
 * WireGuard public key (the shell connector path), vs the keygen path
 * in `provision_device`.
 */

import { z } from "zod";
import type { Wg0Client } from "../client.js";
import type { Tool } from "./types.js";

export function enrollmentTools(client: Wg0Client): Tool[] {
  return [
    {
      name: "generate_enrollment_token",
      description:
        "Mint an enrollment token for a network. Tokens are handed to the shell connector's `enroll` subcommand or any other agent that brings its own WireGuard keypair. Single-use by default; pass is_reusable=true for a long-lived MSP provisioning token.",
      inputSchema: z.object({
        network_id: z.string().uuid(),
        is_reusable: z.boolean().default(false),
        expires_at: z
          .string()
          .datetime()
          .optional()
          .describe(
            "ISO-8601 UTC. Omit for a token that doesn't auto-expire.",
          ),
      }),
      handler: async (args) =>
        client.post("/api/v1/enroll/generate-token", args),
    },
  ];
}
