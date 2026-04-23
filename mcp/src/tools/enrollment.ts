/**
 * Enrollment token tools. For enrolling a device that supplies its own
 * WireGuard public key (the shell connector path + the wg0 native
 * Android/iOS app path), vs the brain-keygen path in `provision_device`.
 */

import { z } from "zod";
import type { Wg0Client } from "../client.js";
import type { Tool } from "./types.js";

interface BrainTokenResponse {
  token_value: string;
  network_id: string;
  is_reusable: boolean;
  expires_at: string | null;
}

export function enrollmentTools(client: Wg0Client): Tool[] {
  return [
    {
      name: "generate_enrollment_token",
      description:
        "Mint an enrollment token for a network. Returns the raw token AND a `managed_enroll_uri` of the form `wg0://enroll?token=…&base=…` that the wg0 native apps (Android alpha18+; iOS not started yet) accept — render that URI as a QR and scan it with the native app for a fully-managed enrollment (device generates its own keypair locally; no private key crosses the wire). The raw token value is what the shell connector's `enroll` subcommand consumes. Single-use by default; pass is_reusable=true for a long-lived MSP provisioning token. For stock-WireGuard mobile app users who don't have a wg0 app installed, use `provision_device` instead — the brain generates a keypair server-side and returns a ready-to-scan wg_config QR.",
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
      handler: async (args) => {
        const token = await client.post<BrainTokenResponse>(
          "/api/v1/enroll/generate-token",
          args,
        );
        const base = client.getBrainUrl();
        const managedUri =
          `wg0://enroll?token=${encodeURIComponent(token.token_value)}` +
          `&base=${encodeURIComponent(base)}`;
        return {
          ...token,
          managed_enroll_uri: managedUri,
          managed_enroll_notes: [
            "Render `managed_enroll_uri` as a QR and scan it with the wg0 Android native app (alpha18+) to enroll without a server-side keypair.",
            "iOS native app: not started yet. Once shipped it will accept the same wg0:// URI format.",
            "Shell connectors (Linux/macOS/Docker/Windows PS) consume `token_value` directly via their `enroll` subcommand — they don't use the managed URI.",
            "For plain stock-WireGuard mobile apps (no wg0 app), use the `provision_device` tool instead; it emits a ready wg_config QR.",
          ],
        };
      },
    },
  ];
}
