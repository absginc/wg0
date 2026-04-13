# wg0 MCP server — containerized stdio variant
#
# Usage from Claude Desktop:
#
#   "wg0": {
#     "command": "docker",
#     "args": [
#       "run", "-i", "--rm",
#       "-e", "WG0_BRAIN_URL=https://connect.wg0.io",
#       "-e", "WG0_API_KEY",
#       "wg0/mcp-server:latest"
#     ],
#     "env": { "WG0_API_KEY": "wg0_pat_REPLACE_ME" }
#   }
#
# The container is a plain Node 20 image with the compiled bundle.
# It runs as a non-root user and has no persistent volumes or
# exposed ports — stdio is the only interface.

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
ENTRYPOINT ["node", "dist/index.js"]
