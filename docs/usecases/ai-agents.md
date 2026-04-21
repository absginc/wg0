# wg0 for AI agents, automation, and API-driven workflows

**Tagline:** Operate your WireGuard private network from Claude
Desktop, a cron job, a CI pipeline, or a homegrown automation
agent — via a documented REST API, an OpenAPI spec, a
Model Context Protocol server, and long-lived personal access
tokens.

**Who this is for:**
- Developers who want their coding agent (Claude Code, Cursor,
  Continue) to be able to inspect and manage their wg0 networks
  while helping them work
- Ops teams automating onboarding, audits, and health monitoring
  across many networks
- MSPs building provisioning pipelines that include private
  networking as a step
- Anyone building an internal AI assistant ("claude, what's the
  state of my mesh?") who needs programmatic access to their
  infrastructure

**Primary pain point it solves:**

Most networking products treat their API as a second-class
citizen. You get a dashboard, and maybe a "reference API" that
was generated from the same handlers but isn't really expected
to be used. The result is: human-friendly UX, machine-hostile
everything else.

AI agents change that equation. An agent that can read your API
docs and make informed decisions about what to do next is only
as good as the docs and the auth model let it be. A mesh VPN
product that requires a browser login to mint automation
credentials, or that has no machine-readable endpoint catalog,
or that returns unhelpful errors, breaks down the moment you
try to operate it from a non-human client.

wg0 is built with "an agent should be able to understand and
operate this" as a first-class goal. The API is documented, the
auth is long-lived and revokable, the state is machine-readable,
and there's a pre-built MCP server that wraps every useful
operation as a tool.

## What wg0 gives agents today

- **Public OpenAPI 3.1 spec** at `https://wg0.io/openapi.yaml` —
  every endpoint, every auth scheme, every request and response
  shape. Feed it to `openapi-generator-cli` to produce a typed
  client in any language, or directly into an agent's tool
  loader.
- **llmstxt.org agent index** at `https://wg0.io/llms.txt` —
  project summary plus prioritized links to the canonical docs
  (README, DEVICE_PROTOCOL, BYO_EXIT, TESTING_ROADMAP, CHANGELOG,
  ROADBLOCKS, MARKETING_TAILORS, API.md, openapi.yaml, MCP.md).
  Any LLM that hits wg0.io/llms.txt gets a curated entry point
  and can decide what to read next.
- **Humans-first API guide** at `https://wg0.io/API.md` —
  endpoint map, auth cheat sheet, six copy-pasteable task
  recipes (register → create network → enroll → heartbeat, QR
  provision, route-all toggle, BYO Exit upload, rotate secret,
  v2 strict POST, mint/use/revoke a PAT). Good for agents that
  prefer structured natural language to raw YAML.
- **Model Context Protocol server** — stdio MCP server that
  wraps 16 wg0 operations as tools (list networks, create
  network, list nodes, update node, provision device, generate
  enrollment token, list/create/delete/activate/deactivate BYO
  exits, node traffic, network traffic, health check), exposes
  the canonical docs as 3 resources, and ships 4 pre-baked
  task-starter prompts (audit_networks, provision_mobile_device,
  activate_byo_exit, roaming_investigation). Works with Claude
  Desktop, Claude Code, Cursor, and any other MCP-aware agent.
  Authenticates via a PAT you mint from the dashboard. See
  `docs/MCP.md` for the full install guide.
- **Personal Access Tokens (PATs)** — long-lived automation
  credentials with optional expiration dates. Format
  `wg0_pat_<43 chars>`, self-identifying so secret scanners can
  detect leaks. Mint from the dashboard UI or via the API.
  Revokable instantly.
- **PAT auth boundary** — PAT management endpoints (create,
  list, revoke) are strictly JWT-only. A leaked PAT cannot mint
  successor credentials or revoke its siblings. Enforced at the
  Rust type level, not just via documentation.
- **Machine-friendly error responses** — all 4xx / 5xx responses
  return structured JSON with a `detail` field explaining what
  went wrong. Agents can read the error and try again with
  corrected inputs.
- **Consistent pagination / sort / filter semantics** — where
  applicable. Most list endpoints are non-paginated for now
  because the result set is small; this will change if it
  becomes a problem.
- **Every endpoint documented in the brain's source** — the Rust
  handlers carry doc comments that describe expected shapes,
  constraints, and edge cases. Good for humans reading the
  code and for agents that have access to the repo.

## What's honestly NOT yet agent-ready

- **No fine-grained scopes on PATs.** Every PAT today has the
  same authority as the owning user's login session (minus PAT
  management, which is JWT-only). You can't mint a read-only
  PAT for "let Claude query my networks but not change
  anything." This is tracked as a follow-up in
  `docs/ROADBLOCKS.md` §9.
- **No OAuth client credentials flow.** If your integrator
  needs OAuth 2.0 client credentials, that's roadmap. For now,
  PATs cover the common "automation needs long-lived auth" case.
- **No SSO / SAML.** If your ops team wants to use their
  corporate SSO to log in and mint PATs, that's roadmap.
- **No MCP directory listing.** We haven't published the MCP
  server to Anthropic's official directory yet. To use it, you
  clone the repo and `npm install && npm run build`. Roadmap.
- **No GitHub Secret Scanning partnership.** The `wg0_pat_`
  prefix is deliberately self-identifying so GitHub's secret
  scanner can detect leaks, but we haven't registered with
  the partner program yet. Roadmap (operational task, not
  engineering).
- **No per-call rate limits or metrics on PATs.** Today we
  store `last_used_at` but not a call counter. Adding per-token
  usage metrics is a small follow-up task.

## Recommended setup pattern

**Scenario: you want Claude Desktop to manage your wg0
deployment from natural-language prompts.**

1. Log in at `https://login.wg0.io` (or your self-hosted
   dashboard).
2. Click **API keys** in the sidebar. Click **+ New token**.
3. Name it something like `claude-desktop`. Optionally set an
   expiration date (recommended for anything long-lived).
4. Click **Mint token**. Copy the plaintext from the dialog
   (it's shown once — if you close the dialog without copying,
   you have to revoke and mint a new one).
5. Paste the token into Claude Desktop's
   `claude_desktop_config.json` as the `WG0_API_KEY` env var.
   See `docs/MCP.md` Step 3 for the exact JSON.
6. Build the MCP server locally:
   ```bash
   git clone https://github.com/absginc/wg0
   cd wg0/mcp
   npm install && npm run build
   ```
7. Point Claude Desktop at `dist/index.js`. Restart Claude
   Desktop. "wg0" should appear in the MCP server badge.
8. Ask Claude: "List all my wg0 networks and flag anything that
   looks unusual." It will call `list_networks`, then
   `list_nodes` for each, and give you a coherent report.

## Representative workflows agents can run today

### Audit across networks

> "List all my wg0 networks, count nodes per network, and flag
> any network that has no online nodes or any host that's in
> Offline state for more than a day."

The agent calls `list_networks` once, `list_nodes` once (or
with `network_id` filter per network), and cross-references.
Output is a structured report the user can act on.

### Onboard a new site

> "Create a new native-LAN network called 'branch-3' with
> subnet `192.168.3.0/24`, host tunnel IP `192.168.3.2`, client
> range `192.168.3.200-220`. Then generate an enrollment token
> and give me the exact command to run on the host machine."

The agent calls `create_network`, then
`generate_enrollment_token`, then composes the install
instructions. You run the command on the actual host.

### Provision a mobile device with QR output

> "Provision a new device named 'scott-pixel' in the
> home-native network. It's an Android phone. Render the
> wg_config as a QR code I can scan."

The agent calls `provision_device` with `os_type=android`,
extracts the `wg_config` field, and pipes it into `qrencode -t
ANSI` to render the QR in the terminal. You scan it with the
stock WireGuard app.

### Roaming investigation

> "The device 'scott-macbook-pro' has been showing weird
> presence. Tell me what's going on."

The agent runs the `roaming_investigation` prompt from the MCP
server, which walks through `list_nodes` filtered to that
device, looks at `presence`, `observed_endpoint`,
`last_endpoint`, `last_activity`, `device_kind`, and
`route_all_active`, and gives you a plain-English explanation
of whether anything looks weird.

### BYO Exit health check

> "Is my Mullvad exit healthy on home-host?"

The agent calls `list_nodes`, finds the home-host row, reads
`upstream_exit_health.state`. Answer is green/yellow/red with
the exact `message` field explaining the state.

## What agents CANNOT do (by design)

- **Mint or revoke PATs.** PAT management is JWT-only. If
  Claude Desktop is authenticated to wg0 via a PAT, it cannot
  use that PAT to mint a new one. You have to log in via the
  browser (or via the REST API with email/password) to manage
  PATs.
- **Access the admin surface.** The `/api/v1/admin/*` endpoints
  require the `X-Admin-Key` header, which is separate from PAT
  auth. Agents don't get admin access via PATs; that's a
  deliberate separation.
- **Delete their own account.** Not an MCP tool. You do that
  through the dashboard or via the REST API with a JWT.

This list is short and deliberate. We want agents to be useful
operators for the product, not able to compromise the
security boundary they operate within.

## Sales talking points

**Opening line:** "wg0 is built for AI-era operators. We ship a
full OpenAPI spec, an llms.txt agent index, a working MCP
server for Claude Desktop, and long-lived personal access
tokens with proper auth boundaries. Point your coding agent at
it and it can inspect, audit, and operate your networks
conversationally."

**Follow-up if they mention security:** "PAT management is
strictly separated from regular API access. A PAT can operate
the product but can't mint more PATs or revoke its siblings.
The boundary is enforced in the Rust type system, not just in
docs. And every PAT has an optional expiration and instant
revocation."

**Follow-up if they ask about scopes:** "Scopes are in the
schema but the extractor doesn't honor them yet — every PAT
today has full authority. Scope enforcement (read / write /
admin) is tracked as follow-up. If that's a blocker for you,
tell us and we'll prioritize it."

**Follow-up if they ask about the MCP server:** "Stdio
transport, 16 tools, 3 resources, 4 prompts. Works with Claude
Desktop, Claude Code, Cursor, and anything else that speaks
MCP stdio. It's a TypeScript project; clone the repo, `npm
install`, `npm run build`, point Claude Desktop at
`dist/index.js`. Full install guide at `docs/MCP.md`."

**Closing line:** "We're an early-stage product that takes the
'agents should operate us' goal seriously. We're actively
looking for feedback from agent-first users about what to
ship next. If you're building an internal assistant that
needs private networking, we want to hear from you."

## Related docs

- [`docs/MCP.md`](../MCP.md) — canonical MCP server install
  guide. Covers Claude Desktop, Claude Code, Cursor, and the
  Docker variant.
- [`docs/openapi.yaml`](../openapi.yaml) — machine-readable spec.
- [`docs/llms.txt`](../llms.txt) — agent discovery index.
- [`docs/API.md`](../API.md) — human-friendly API reference.
- [`docs/DEVICE_PROTOCOL.md`](../DEVICE_PROTOCOL.md) — device
  protocol v1 + v2 spec, relevant if the agent needs to
  understand the wire format between connector and brain.
- [`docs/ROADBLOCKS.md`](../ROADBLOCKS.md) §8 (API is useful,
  but not yet agent-ready) + §9 (service-account / scoped
  automation auth).
