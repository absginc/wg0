# wg0 MCP server — install, configure, verify

**Status:** shipped + smoke-tested end-to-end in prod
**Last revised:** 2026-04-17 (remote/OAuth variant added)
**Owner:** Scott
**Source:** [mcp/](../mcp/) (TypeScript stdio + Streamable HTTP server on `@modelcontextprotocol/sdk`)

This is the single source of truth for how to use the wg0 MCP
server from Claude Desktop, Claude Code, Cursor, or any other
MCP-aware agent. If something in this doc goes stale against the
shipped code, fix it here first — this is the doc everything else
in the repo points at.

## What the MCP server is

A Model Context Protocol server that wraps the wg0 brain's REST API
as tools an LLM can call directly. Once configured in an agent host,
the agent can operate your wg0 control plane conversationally: list
networks, provision devices, toggle route-all, activate BYO Exit
upstreams, investigate roaming, and audit presence.

The server ships two interchangeable transports:

- **Remote (Streamable HTTP)** at `https://mcp.wg0.io/mcp`. This is
  the one you want if your agent host has a "paste a URL" dialog —
  Claude Desktop's *Settings → Connectors → Add custom connector*,
  for example. Authentication goes through OAuth 2.1 with Dynamic
  Client Registration, so the user just pastes the URL, clicks
  through a login + approve page in the browser, and the agent
  walks away with a short-lived bearer token. No PAT copy-paste.
- **Local (stdio)**. The agent host spawns `node dist/index.js` as a
  subprocess and talks JSON-RPC over pipes. Uses `WG0_API_KEY`
  (a PAT) in its env. Best for Claude Code, CI, and anyone who'd
  rather configure a JSON file than use a GUI.

Both transports share the same 16 tools, 3 resources, and 4 prompts.

The server exposes three kinds of MCP objects:

- **16 tools** — one per meaningful operation (see tool list below)
- **3 resources** — the canonical wg0 docs (`llms.txt`, `openapi.yaml`,
  `API.md`) served as browsable MCP resources so the agent can load
  them without a user prompt
- **4 task-starter prompts** — common workflows the user can
  trigger from the agent host's UI (command palette in Claude Desktop,
  `/` commands in Claude Code)

## Prerequisites

1. A wg0 account at https://login.wg0.io.
2. **A personal access token** from `POST /api/v1/api-keys` — the
   MCP server authenticates as you via this token, not via a JWT.
   PATs are long-lived and survive browser sessions; JWTs expire in
   hours.
3. Node.js 18+ on whatever machine runs your agent host. The
   agent host spawns the MCP server as a subprocess and talks to
   it over stdio.

## Step 1 — build the MCP server

```bash
git clone https://github.com/absginc/wg0
cd wg0/mcp
npm install
npm run build
```

This produces `dist/index.js`. Note the absolute path — the agent
host's config will point at this file.

```bash
pwd
# e.g. /Users/scott/code/wg0/mcp
# The absolute path to dist/index.js is:
# /Users/scott/code/wg0/mcp/dist/index.js
```

## Step 2 — mint a PAT

### From the dashboard (recommended)

1. Log in at https://login.wg0.io.
2. Click **API keys** in the left sidebar.
3. Click **+ New token**, give it a descriptive name (e.g.
   `claude-desktop`), optionally set an expiration date, click
   **Mint token**.
4. A dialog shows the plaintext token ONCE. Click **Copy** and
   paste it somewhere safe — a password manager, a secrets store,
   or straight into the agent host config in step 3 below.
5. Tick the "I have saved this token" checkbox and click **Done**.

The dashboard also lets you list every token you own (with their
`last_used_at` timestamps for audit), revoke live tokens with one
click, and see a history of revoked tokens. It does NOT let you
see the plaintext of an already-minted token — that's the whole
point of the one-time-display dialog.

### From the command line (automation scripts, CI)

Useful for bootstrapping an environment without a browser. **PAT
management endpoints are JWT-only** — a PAT cannot mint another
PAT, so you always need a fresh login for this step.

```bash
BRAIN=https://connect.wg0.io

# 1. Log in (returns a JWT — lifespan ~24 hours)
JWT=$(curl -sf -X POST "$BRAIN/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"YOUR_EMAIL","password":"YOUR_PASSWORD"}' \
  | jq -r .access_token)

# 2. Mint a PAT for Claude Desktop (or whichever agent host)
curl -sf -X POST "$BRAIN/api/v1/api-keys" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"name":"claude-desktop"}' \
  | jq -r .api_key

# With an expiration date
curl -sf -X POST "$BRAIN/api/v1/api-keys" \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"name":"claude-desktop","expires_at":"2027-01-01T00:00:00Z"}' \
  | jq -r .api_key

# Inspect what you have
curl -sf -H "Authorization: Bearer $JWT" "$BRAIN/api/v1/api-keys" \
  | jq '[.[] | {name, key_prefix, last_used_at, revoked_at}]'

# Revoke a token
curl -sf -X DELETE -H "Authorization: Bearer $JWT" \
  "$BRAIN/api/v1/api-keys/<KEY_ID>"
```

You'll see a token like `wg0_pat_K7aBCd9fGhIjKlMnOpQrStUvWxYz0123456789-_Abc`.

**Capture it now.** The brain only stores the Argon2id hash — if
you lose the plaintext you have to revoke and mint a new one.

## Step 3 — configure your agent host

### Claude Desktop — remote (URL dialog, no PAT copy-paste)

**This is the recommended path** if your Claude Desktop version
shows a "Connectors" screen in Settings.

1. Open **Settings → Connectors → Add custom connector**.
2. Paste `https://mcp.wg0.io/mcp` into the URL field and submit.
3. Claude Desktop fetches `/.well-known/oauth-protected-resource` on
   the MCP host, follows the pointer to the brain's OAuth metadata
   at `https://connect.wg0.io/.well-known/oauth-authorization-server`,
   and auto-registers itself as an OAuth client (RFC 7591). You do
   not see any of this.
4. A browser tab opens at `https://login.wg0.io/oauth/consent?...`.
   If you're not signed in, sign in with your wg0 email + password;
   you'll be bounced back to the consent page automatically.
5. Review the "Authorize <client> to access your wg0 account" card
   and click **Allow**. Claude Desktop is handed a short-lived
   bearer token and you're done — the connector shows as active.

Access tokens are valid for 1 hour and Claude Desktop refreshes
them in the background using a rotating refresh token (30-day TTL).
You can revoke the connector at any time from the API Keys page in
the dashboard — revocation is instant.

The remote MCP server honors refreshed OAuth bearer tokens inside an
already-open MCP session, so normal token rotation should not force a
manual reconnect every hour. If the connector does need to be added
again, treat that as a refresh-token or connector-state problem, not
normal expected behavior.

If the connector shows a token error:

- `Access token expired` usually means the client did not refresh its
  short-lived bearer successfully. Reconnect the connector once.
- `Invalid access token` usually means the token is malformed, revoked,
  or the connector has stale auth state and should be re-authorized.

### Claude Desktop — local (stdio, config file)

Keep using this if your agent host doesn't speak remote MCP yet, or
if you want to run everything on the same machine with a PAT you
control explicitly.

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "wg0": {
      "command": "node",
      "args": [
        "/Users/scott/code/wg0/mcp/dist/index.js"
      ],
      "env": {
        "WG0_BRAIN_URL": "https://connect.wg0.io",
        "WG0_API_KEY": "wg0_pat_PASTE_FROM_STEP_2"
      }
    }
  }
}
```

Quit and restart Claude Desktop completely. In the chat input you
should now see a small "MCP" badge showing one server connected.
Clicking it lists the tools wg0 exposes.

### Claude Desktop (Linux)

`~/.config/Claude/claude_desktop_config.json` — same JSON shape.

### Claude Desktop (Windows)

`%APPDATA%\Claude\claude_desktop_config.json` — same JSON shape.
Path in `args` uses forward slashes or escaped backslashes.

### Claude Code

Claude Code reads MCP servers from `~/.config/claude-code/mcp.json`
(user-level) or `.claude-code/mcp.json` (project-level). The JSON
shape is the same as Claude Desktop:

```json
{
  "mcpServers": {
    "wg0": {
      "command": "node",
      "args": ["/abs/path/to/wg0/mcp/dist/index.js"],
      "env": {
        "WG0_BRAIN_URL": "https://connect.wg0.io",
        "WG0_API_KEY": "wg0_pat_PASTE_FROM_STEP_2"
      }
    }
  }
}
```

For a repo-specific setup, put the config in the project's
`.claude-code/mcp.json` so the MCP server only activates when
Claude Code is launched from inside that repo.

### Cursor / other MCP clients

Any MCP-aware agent host that supports stdio transport can use
this server. The command is `node`, the args are
`["/abs/path/to/dist/index.js"]`, and the required env vars are
`WG0_BRAIN_URL` + `WG0_API_KEY`.

### Docker variant (optional)

If you prefer containerization, a Dockerfile is in [mcp/Dockerfile](../mcp/Dockerfile).
Build it once:

```bash
cd wg0/mcp
docker build -t wg0/mcp-server:latest .
```

Then point the agent host at docker:

```json
{
  "mcpServers": {
    "wg0": {
      "command": "docker",
      "args": [
        "run", "-i", "--rm",
        "-e", "WG0_BRAIN_URL=https://connect.wg0.io",
        "-e", "WG0_API_KEY",
        "wg0/mcp-server:latest"
      ],
      "env": {
        "WG0_API_KEY": "wg0_pat_PASTE_FROM_STEP_2"
      }
    }
  }
}
```

The env var passthrough (`-e WG0_API_KEY` with no value) pulls
the variable from the host's `env` block in the config, keeping
the PAT out of the command line.

## Step 4 — verify it works

Once the agent host shows wg0 as an active MCP server, try
the simplest possible prompt first:

> "Call the wg0 health_check tool and report what it returns."

Expected: the agent calls `health_check`, the MCP server calls
`GET https://connect.wg0.io/health`, and you see
`{"status":"ok","service":"wg0-brain"}` in the response.

Then a slightly richer one:

> "List all my wg0 networks and show the per-network node counts."

Expected: the agent calls `list_networks`, you see every network
you own with `node_count` + `online_count` (online_count follows
the four-state presence model — Online + Observed both count as
up).

## Tool list

The shipped server exposes tools across these families. Counts reflect
the state of `mcp/src/tools/*.ts` after the shared-networks + devices +
site-access additions; if the agent host shows a different number on
`tools/list`, the build is out of sync — rebuild `mcp/` and restart
the host.

### Networks + nodes

| Tool | Purpose |
|---|---|
| `health_check` | Probe the brain. Use this first in any workflow. |
| `list_networks` | Every network with `node_count`, `online_count`, `tx_bytes`, `rx_bytes`. |
| `create_network` | Overlay (auto-assigned subnet) or native-LAN (needs gateway subnet + host tunnel IP + client range). |
| `delete_network` | Destructive — removes the network and every node inside. |
| `list_nodes` | Per-node `presence`, `observed_endpoint`, `last_activity`, `device_kind`, `route_all_active`, `on_host_lan`. Optional `network_id` filter. |
| `update_node` | Rename, toggle `route_all_traffic`, set/clear `current_upstream_exit_id`. |
| `delete_node` | Remove a node, unregister from discover sidecar. |

### Managed devices (multi-network)

| Tool | Purpose |
|---|---|
| `list_devices` | Every managed device with its memberships, telemetry, and installation id. |
| `get_device` | Single device detail including all active memberships. |
| `get_device_endpoint_history` | Roaming history for the device as a whole, not a single membership. |
| `get_device_peerings` | Relay / direct-peer status per membership. |
| `update_device` | Rename, toggle `collect_device_telemetry`, etc. |
| `delete_device` | Destructive — removes the device and all its memberships. |
| `preflight_device_attach` | Check route conflicts + capability gates before attaching. |
| `attach_device_to_network` | Request + fulfill an attach to a second network owned by this account. |
| `update_device_membership` | Per-membership patch (route-all, name, advertised_routes). |
| `remove_device_membership` | Detach from one network; device stays alive + other memberships untouched. |
| `provision_device` | Server-side keygen + enroll for the mobile/QR flow. Returns full `wg_config` with `PrivateKey` populated. |
| `generate_enrollment_token` | Mint a token for the bring-your-own-key enrollment path (shell connector). |

### Shared networks (cross-account)

| Tool | Purpose |
|---|---|
| `list_shared_network_access` | Shared networks the caller is a member of. |
| `create_shared_network_invite` | Owner/admin mints an email invite (7-day expiry). |
| `revoke_shared_network_invite` | Pull a pending invite before it's accepted. |
| `revoke_shared_network_member` | Remove a guest from the shared network. |
| `revoke_shared_network_device` | Detach one of the guest's devices without removing the membership. |
| `generate_shared_network_enrollment_token` | Guest mints a single-use enrollment token scoped to the shared network. |
| `preflight_shared_network_attach` | Preflight the attach against the guest's active device memberships. |
| `attach_device_to_shared_network` | Attach an existing device to a shared network (instead of enrolling fresh). |

### Site access (gateway exports + access grants)

| Tool | Purpose |
|---|---|
| `list_gateway_exports` | Gateway-exported routes per host node. |
| `create_gateway_export` | Advertise specific LAN subnets from a host into a hub_spoke access network. |
| `update_gateway_export` | Toggle active flag, rename, change exported_routes. |
| `delete_gateway_export` | Remove an export. |
| `list_access_grants` | Subjects (user / device_profile / device) with access to each export. |
| `create_access_grant` | Bind a subject to a gateway export. |
| `update_access_grant` | Toggle active / re-scope. |
| `delete_access_grant` | Hard-remove a grant. |

### BYO Exit + traffic

| Tool | Purpose |
|---|---|
| `list_upstream_exits` | BYO Exit inventory per host. `wg_config` excluded for safety. |
| `create_upstream_exit` | Upload a provider wg-config (Mullvad, Proton, Azire, custom). |
| `delete_upstream_exit` | Remove an upstream permanently. |
| `activate_upstream_exit` | Set the host's active upstream. Route-all clients inherit it next heartbeat. |
| `deactivate_upstream_exit` | Revert the host to physical WAN. |
| `get_node_traffic` | Hourly TX/RX buckets for a single node (last N hours, default 24). |
| `get_network_traffic` | Aggregated hourly TX/RX for an entire network. |

### Deliberately not exposed

- `create_api_key` / `revoke_api_key` / `list_api_keys` — PAT
  management tools are JWT-only at the brain level, and even if
  they weren't, exposing them to an agent would let the agent
  mint its own successor credentials or lock you out. Manage PATs
  from the dashboard (when the UI ships) or via `curl`.
- Admin surface (`/api/v1/admin/*`) — gated by `X-Admin-Key`, not
  a PAT. Admin operations are for ops, not agents.

## Resources (3)

| URI | Upstream | Purpose |
|---|---|---|
| `wg0://docs/llms.txt` | https://wg0.io/llms.txt | llmstxt.org-compliant agent index |
| `wg0://docs/openapi.yaml` | https://wg0.io/openapi.yaml | Full OpenAPI 3.1 spec |
| `wg0://docs/API.md` | https://wg0.io/API.md | Human-friendly API guide |

Agents that read these on demand get the full product context
without the user having to paste docs in.

## Prompts (4)

| Prompt | Arguments | Purpose |
|---|---|---|
| `audit_networks` | (none) | Walk every network, show node counts + presence, flag unusual state. |
| `provision_mobile_device` | `network_name`, `device_name` | End-to-end QR provisioning with wg_config output. |
| `activate_byo_exit` | `host_name`, `exit_name` | Flip an upstream exit on a host. |
| `roaming_investigation` | `device_name` | Diagnostic walkthrough for a device whose `observed_endpoint` keeps changing. |

In Claude Desktop, these surface in the command palette. In
Claude Code, they appear under the `/` prompt menu.

## Troubleshooting

### "wg0-mcp: WG0_API_KEY is required"

The agent host spawned the server but didn't pass the env var.
Check the `env` block in the agent host config — `WG0_API_KEY`
must be set. For Docker variants, also check the
`-e WG0_API_KEY` passthrough.

### "wg0-mcp: WG0_API_KEY must start with 'wg0_pat_'"

You passed a JWT. JWTs expire in hours and aren't accepted here —
mint a PAT via Step 2.

### MCP server shows as disconnected in the agent host

Check the agent host's log for the MCP subprocess. Claude Desktop
logs MCP stdio to the app log directory (`~/Library/Logs/Claude/`
on macOS). Look for lines starting with `wg0-mcp:` — the boot
banner goes to stderr and should read:

```
wg0-mcp: ready. brain=https://connect.wg0.io, tools=16, resources=3, prompts=4
```

If you see a different number of tools, the build is out of sync —
re-run `npm run build` in `mcp/` and restart the agent host.

### Tool call returns "Invalid API token"

Your PAT is revoked or expired. List your PATs via `curl`
(see "Inspecting what you have" in Step 2) and either mint a new
one or un-revoke the old one (not supported — just mint new).

### Tool call returns a brain error

Error messages from the brain propagate up as MCP tool errors
with `isError: true` and the full response body attached. The
agent will see it in the `content[0].text` field of the tool
response and should explain it back. Common examples:

- `"node_name is required"` — missing field in `create_network` /
  `create_upstream_exit` / etc.
- `"route_all_traffic can only be set on clients"` — guardrail
  hit in `update_node`.
- `"404 Not Found"` — wrong UUID. Always start with `list_networks`
  or `list_nodes` to get the right id.

### Verifying the build works without an agent host

You can speak MCP JSON-RPC to the compiled binary manually for a
smoke test:

```bash
cd wg0/mcp
# Replace with your real PAT
export WG0_API_KEY=wg0_pat_...
export WG0_BRAIN_URL=https://connect.wg0.io

node dist/index.js <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"manual","version":"0"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"health_check","arguments":{}}}
EOF
```

You should see three JSON-RPC responses on stdout and the boot
banner on stderr.

## Security notes

- **Treat your PAT like a production database password.** It has
  the same authority as your JWT on every wg0 endpoint EXCEPT the
  PAT management endpoints (which are strictly JWT-only to prevent
  credential escalation — see ROADBLOCKS.md §9).
- **Revoke on suspicion.** If you think a PAT has leaked or the
  machine holding it has been compromised, revoke immediately:
  `DELETE /api/v1/api-keys/:id`. Revocation is instant — no
  cache, no grace period.
- **Rotate periodically.** Mint a new PAT, update the agent host
  config, restart the agent host, revoke the old PAT. The
  rotate-secret endpoint on `/api/v1/nodes/:id/rotate-secret` is
  for device secrets, not PATs.
- **Don't commit PATs.** The PAT format is self-identifying
  (`wg0_pat_` prefix) precisely so secret scanners like GitHub
  Secret Scanning can detect accidental commits. If you leak one
  into a public repo, revoke within minutes.
- **Don't give a PAT to an untrusted agent.** Any agent with the
  PAT can do anything the account can do (other than manage other
  PATs). If you're running an agent you don't fully trust,
  mint a dedicated PAT for it with a short `expires_at`, and
  revoke the moment you're done.

## Development workflow

### Rebuilding after source changes

```bash
cd wg0/mcp
npm run build        # one-shot
npm run dev          # tsc --watch, rebuild on every save
```

After a rebuild, restart the agent host so it re-spawns the MCP
subprocess with the fresh bundle.

### Adding a new tool

1. Add a new tool object to the appropriate file under
   `mcp/src/tools/*.ts` (or create a new file for a new category).
2. Export its constructor function and register it in
   `mcp/src/index.ts` alongside the others.
3. Rebuild. The agent will see the new tool on its next
   `tools/list` call, which happens automatically on server
   initialization.
4. Update this doc's tool list table.

### Changing the JSON Schema converter

The `zodToJsonSchema` walker in `mcp/src/index.ts` covers only the
zod shapes the existing tools use (`ZodObject`, `ZodString`,
`ZodNumber`, `ZodBoolean`, `ZodEnum`, `ZodArray`, `ZodOptional`,
`ZodDefault`, plus uuid/datetime/email format hints via
`ZodString` checks). If you add a tool that uses a different
zod type, either extend the walker or pull in
`zod-to-json-schema` as a dependency.

## Related docs

- [mcp/README.md](../mcp/README.md) — condensed install guide bundled with the source
- [docs/ROADBLOCKS.md §8, §9](./ROADBLOCKS.md) — the strategic case for agent-readiness + PAT boundaries
- [docs/DEVICE_PROTOCOL.md](./DEVICE_PROTOCOL.md) — the separate device-side protocol (connectors, not agents)
- [docs/API.md](./API.md) — human-first API reference covering everything the MCP server wraps
- [docs/openapi.yaml](./openapi.yaml) — machine-readable spec for every endpoint
- [CHANGELOG.md](../CHANGELOG.md) — the MCP server landing entry + the PAT auth boundary entry that followed
