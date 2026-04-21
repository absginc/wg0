# wg0 MCP server — dual-mode container.
#
# Default: stdio mode (WG0_MCP_MODE unset). One PAT per process via
# WG0_API_KEY. Suitable for `docker run -i --rm …` from Claude Desktop.
#
# Long-running HTTP mode: set WG0_MCP_MODE=http and PORT=8090. Exposes
# Streamable HTTP at /mcp with per-session Bearer auth (PAT today,
# OAuth access tokens once the brain-side DCR endpoints ship). Use
# this for `mcp.wg0.io`-style deployments.
#
# Build: docker build -t wg0/mcp-server:latest mcp/

FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json tsconfig.json ./
COPY src ./src
RUN npm install --no-audit --no-fund \
 && npm run build \
 && npm prune --omit=dev

FROM node:20-alpine AS runtime
WORKDIR /app
# Non-root user for defense in depth — the server only speaks stdio
# and makes outbound HTTPS calls, so there's no reason to run as
# root.
RUN addgroup -S wg0 && adduser -S wg0 -G wg0
COPY --from=builder /app/package.json ./
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
USER wg0
# HTTP mode containers should EXPOSE $PORT at deploy time; stdio mode
# ignores it. No EXPOSE directive here because stdio is the default
# and leaving a declared port would be misleading for that variant.
ENTRYPOINT ["node", "dist/index.js"]
