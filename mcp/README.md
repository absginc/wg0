# wg0 MCP server

Model Context Protocol server that exposes the wg0 brain's REST API
as MCP tools. Lets any MCP-aware agent (Claude Desktop, Claude Code,
Cursor, custom agents) operate a wg0 control plane conversationally.

> **Full integration guide, PAT minting instructions, troubleshooting,
> tool list, and security notes live in [docs/MCP.md](../docs/MCP.md).**
> That doc is the single source of truth; this README is a condensed
> build/install reference bundled with the source.

## What this gives you

Once installed in your agent host, you can ask things like:

- "Audit all my wg0 networks and flag anything unusual."
- "Provision a new mobile device named 'work-phone' in the home-native network."
- "Turn on route-all traffic for Scott's MacBook Pro."
- "Activate the Mullvad SE upstream exit on home-host."
- "Show me the last 24 hours of traffic for Scotts-MacBook-Pro."

The agent calls the brain through this MCP server using a personal
access token (PAT) you mint under your account — no JWT juggling,
no long-lived browser sessions.

## Prerequisites

1. A wg0 account at https://login.wg0.io.
2. A personal access token minted via `POST /api/v1/api-keys` —
   your dashboard will have a management UI once that lands, in the
   meantime use `curl` per [docs/API.md](https://wg0.io/API.md#6-mint-a-pat-and-use-it-for-automation).
3. Node.js 18+ on whatever machine runs your agent.

## Install

```bash
git clone https://github.com/absginc/wg0
cd wg0/mcp
npm install
npm run build
```

This produces `dist/index.js`, the executable MCP server entry point.

## Configure in Claude Desktop

Edit your `claude_desktop_config.json`:

- **macOS:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Linux:** `~/.config/Claude/claude_desktop_config.json`
- **Windows:** `%APPDATA%\Claude\claude_desktop_config.json`

Add this under `mcpServers`:

```json
{
  "mcpServers": {
    "wg0": {
      "command": "node",
      "args": ["/absolute/path/to/wg0/mcp/dist/index.js"],
      "env": {
        "WG0_BRAIN_URL": "https://connect.wg0.io",
        "WG0_API_KEY": "wg0_pat_REPLACE_ME"
      }
    }
  }
}
```

Restart Claude Desktop. You should see "wg0" under the MCP servers
badge in the chat input. The server will expose ~15 tools, 3
documentation resources, and 4 task-starter prompts.

## Tools

| Tool | Purpose |
|---|---|
| `health_check` | Probe the brain before any workflow |
| `list_networks` | Canonical first call — returns every network with counts |
| `create_network` | Create overlay or native-LAN network |
| `delete_network` | Destructive — removes network and every node in it |
| `list_nodes` | Per-node presence, observed_endpoint, device_kind, route_all_active |
| `update_node` | Rename, toggle route_all_traffic, change/clear upstream exit |
| `delete_node` | Remove a node, unregister from discover |
| `provision_device` | Server-side keygen for QR/mobile flow |
| `generate_enrollment_token` | Bring-your-own-key enrollment path |
| `list_upstream_exits` | BYO Exit inventory per host |
| `create_upstream_exit` | Upload a provider wg-config |
| `delete_upstream_exit` | Remove an upstream exit permanently |
| `activate_upstream_exit` | Set the host's active upstream |
| `deactivate_upstream_exit` | Revert the host to physical WAN |
| `get_node_traffic` | Hourly TX/RX buckets for a single node |
| `get_network_traffic` | Aggregated hourly TX/RX for an entire network |

## Resources

The server exposes wg0's product docs as read-only MCP resources so
the agent can load context on demand:

- `wg0://docs/llms.txt` — agent index pointing at all canonical docs
- `wg0://docs/openapi.yaml` — full OpenAPI 3.1 spec
- `wg0://docs/API.md` — humans-first API guide

## Prompts

Starter prompts for common workflows:

- `audit_networks` — walk every network and flag unusual state
- `provision_mobile_device` — end-to-end mobile enrollment with QR rendering
- `activate_byo_exit` — flip an upstream exit on a host
- `roaming_investigation` — diagnostic walkthrough for a roaming device

## Scope + safety

This MCP server is a thin wrapper around the wg0 brain API. It does
NOT do its own authentication, authorization, or rate limiting —
every request is made as your PAT, which has the same authority as
your JWT (full-account access). See
[docs/ROADBLOCKS.md §9](https://github.com/absginc/wg0/blob/main/docs/ROADBLOCKS.md)
for the fine-grained scope enforcement roadmap.

Until scopes are enforced:

- Treat your wg0 PAT like a production database password.
- Never hand the PAT to an untrusted agent.
- If you suspect leakage, revoke it immediately via
  `DELETE /api/v1/api-keys/:id`.

The server deliberately does NOT expose PAT management tools
(`create_api_key` / `revoke_api_key`) — an agent shouldn't be able
to mint its own successor credentials or lock you out by revoking
the one you gave it. Manage PATs from the dashboard or via `curl`.

## Development

```bash
npm run dev      # tsc --watch, rebuild on change
npm run build    # one-shot build
node dist/index.js  # manual run (needs WG0_API_KEY in env)
```

For a smoke test without Claude Desktop, you can speak stdio
JSON-RPC to the binary directly — see the smoke test script in
the main repo under `mcp/smoke.sh` (if present).

## License

Proprietary — ships with the wg0 brain. See the top-level repo.
