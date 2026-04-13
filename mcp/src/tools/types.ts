/**
 * Shared tool shape. Each tool exposes a zod input schema for validation
 * (which MCP converts to JSON Schema for the client) and a handler that
 * takes validated args and returns any JSON-serializable result.
 */

import type { z } from "zod";

export interface Tool<TInput = any, TOutput = unknown> {
  name: string;
  description: string;
  inputSchema: z.ZodType<TInput>;
  handler: (args: TInput) => Promise<TOutput>;
}
