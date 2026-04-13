# wg0 API — human-friendly reference

**Machine-readable spec:** [openapi.yaml](./openapi.yaml)
**Agents index:** [llms.txt](./llms.txt)

This is the quick-reference counterpart to the OpenAPI spec. Use the
OpenAPI file if you want to generate a client or hand it to a tool.
Use this file if you want to quickly understand what every endpoint
does and which auth scheme it needs.

Production base URL: `https://connect.wg0.io`
Local dev base URL: `http://localhost:8000`

## Authentication cheat sheet

| Header / field | Scheme | Used by |
|---|---|---|
| `Authorization: Bearer <JWT>` | `bearerAuth` | humans via the dashboard |
| `Authorization: Bearer wg0_pat_...` | `bearerAuth` (PAT variant) | long-lived automation / MSP tooling / MCP |
| `X-Device-Secret: <secret>` | `deviceSecret` | v1 device-authenticated endpoints |
| `X-Device-Secret` + `Wg0-Protocol-Version: 2` | `strictDeviceAuth` | v2 device endpoints |
| `X-Admin-Key: <key>` | `adminKey` | `/api/v1/admin/*` |
| `token` field in request body | `enrollmentToken` | `POST /api/v1/enroll/register` only |

**PAT vs JWT:** any endpoint that accepts `Authorization: Bearer <JWT>`
also accepts `Authorization: Bearer wg0_pat_...`. The brain detects
the prefix and routes accordingly.

**PAT management endpoints are JWT-only.** `POST`, `GET`, and
`DELETE` on `/api/v1/api-keys[/:id]` all reject PAT bearers with
401. A leaked PAT cannot mint successor credentials (credential
escalation), list sibling credentials (recon), or revoke them
(availability attack). Managing PATs requires fresh proof that
the caller is the human owner — which means re-logging in via
`/api/v1/auth/login` and using the resulting JWT.

## Endpoint map

### Auth
- `POST /api/v1/auth/register` — create account, returns JWT
- `POST /api/v1/auth/login` — exchange email+password for JWT

### API keys (personal access tokens) — **JWT-only**
- `POST /api/v1/api-keys` — mint a PAT (returns plaintext once)
- `GET /api/v1/api-keys` — list PATs with prefix + metadata (never plaintext)
- `DELETE /api/v1/api-keys/:id` — revoke a PAT (idempotent)

All three reject PAT bearers. Use the JWT from `/api/v1/auth/login`.

### Networks
- `GET /api/v1/networks` — list with aggregate counts (nodes, online,
  tx/rx bytes)
- `POST /api/v1/networks` — create overlay or native-LAN network
- `DELETE /api/v1/networks/:id` — destroy network + all its nodes

### Enrollment
- `POST /api/v1/enroll/generate-token` — mint an enrollment token (JWT)
- `POST /api/v1/enroll/register` — bring-your-own-key enrollment (token)
- `POST /api/v1/networks/:id/provision` — server-side keygen for QR/mobile (JWT)

### Nodes (owner surface)
- `GET /api/v1/nodes` — list nodes with derived presence/last_activity/observed_endpoint
- `PATCH /api/v1/nodes/:id` — update `node_name` / `route_all_traffic` /
  `current_upstream_exit_id` / `clear_upstream_exit`
- `DELETE /api/v1/nodes/:id` — destroy a node

### Device protocol v1 (device-authenticated)
- `POST /api/v1/nodes/:id/heartbeat` — managed connector heartbeat
- `DELETE /api/v1/nodes/:id/self` — connector self-unenroll
- `GET /api/v1/nodes/:id/config` — fetch fresh wg_config for drift recovery
- `POST /api/v1/nodes/:id/rotate-secret` — rotate the per-device secret

### Device protocol v2 (strict, versioned)
- `POST /api/v2/devices/:id/state` — report current state + receive desired state
- `GET /api/v2/devices/:id/state` — desired-state poll

### BYO Exit
- `GET /api/v1/nodes/:id/upstream-exits` — list exits attached to a host
- `POST /api/v1/nodes/:id/upstream-exits` — upload a provider config
- `DELETE /api/v1/upstream-exits/:id` — remove an exit

### Traffic
- `GET /api/v1/nodes/:id/traffic?hours=24` — time-series per node
- `GET /api/v1/networks/:id/traffic?hours=24` — aggregated per network

### Admin (X-Admin-Key)
- `GET /api/v1/admin/stats` — platform-wide counters + four-state presence
  breakdown (`online_nodes`, `observed_nodes`, `offline_nodes`, `unknown_nodes`)
- `GET /api/v1/admin/accounts` — every account with network + node counts
- `GET /api/v1/admin/nodes` — every enrolled node with derived presence
- `GET /api/v1/admin/networks` — every network with per-network counts
- `GET /api/v1/admin/traffic` — per-account / per-network traffic totals

### Health
- `GET /health` — liveness probe (no auth)

## Common task recipes

### 1. Register, create a network, enroll a node, start a heartbeat loop

```bash
BRAIN=https://connect.wg0.io

# Register
TOKEN=$(curl -sf -X POST "$BRAIN/api/v1/auth/register" \
  -H "Content-Type: application/json" \
  -d '{"email":"ops@example.com","password":"correct horse battery staple"}' \
  | jq -r .access_token)

# Create an overlay network
NET_ID=$(curl -sf -X POST "$BRAIN/api/v1/networks" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"first-mesh"}' \
  | jq -r .id)

# Mint a single-use enrollment token
ENR_TOKEN=$(curl -sf -X POST "$BRAIN/api/v1/enroll/generate-token" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"network_id\":\"$NET_ID\"}" \
  | jq -r .token_value)

# Generate a WireGuard keypair locally and enroll
PRIV=$(wg genkey)
PUB=$(echo "$PRIV" | wg pubkey)
RESP=$(curl -sf -X POST "$BRAIN/api/v1/enroll/register" \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"$ENR_TOKEN\",\"node_name\":\"vps-1\",\"public_key\":\"$PUB\",\"role\":\"client\"}")

NODE_ID=$(echo "$RESP" | jq -r .node_id)
DEVICE_SECRET=$(echo "$RESP" | jq -r .device_secret)

# First heartbeat (with the device secret for strict auth compatibility)
curl -sf -X POST "$BRAIN/api/v1/nodes/$NODE_ID/heartbeat" \
  -H "X-Device-Secret: $DEVICE_SECRET" -H "Content-Type: application/json" \
  -d '{"endpoint":null,"tx_bytes":0,"rx_bytes":0,"route_all_active":false}'
```

### 2. QR-provision a mobile device (server-side keygen)

```bash
curl -sf -X POST "$BRAIN/api/v1/networks/$NET_ID/provision" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"node_name":"pixel","os_type":"android","role":"client"}' \
  | jq -r .wg_config \
  | qrencode -t ANSI  # print the QR code to the terminal
```

Mobile user scans the QR in the stock WireGuard app. The brain records
the device as `device_kind='provisioned'` — it will never heartbeat,
but the discover sidecar and any managed host on the same network will
report its handshakes. When a managed host reports a fresh handshake
the device shows `online` (authoritative evidence); when only the
discover sidecar sees it the device shows `observed`. The `PEER` badge
in the dashboard is what carries the "this is a stock WireGuard peer
without an agent" distinction — presence stays focused on evidence
strength, not device class. See `brain-rs/src/models.rs::Presence` for
the rationale.

### 3. Toggle route-all on a client

```bash
curl -sf -X PATCH "$BRAIN/api/v1/nodes/$NODE_ID" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"route_all_traffic":true}'
```

The PATCH bumps the node's `config_version`. The client's next
heartbeat will see the new version and call `GET /nodes/:id/config`
to pull fresh config, then `wg syncconf` the live interface.

### 4. Upload a Mullvad upstream + activate on a host

```bash
# Upload
EXIT_ID=$(curl -sf -X POST "$BRAIN/api/v1/nodes/$HOST_ID/upstream-exits" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "$(jq -n --arg wg "$(cat wg-mullvad.conf)" \
        '{name:"Mullvad SE", provider_type:"mullvad", wg_config:$wg}')" \
  | jq -r .id)

# Activate
curl -sf -X PATCH "$BRAIN/api/v1/nodes/$HOST_ID" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"current_upstream_exit_id\":\"$EXIT_ID\"}"
```

### 5. Rotate a device secret

```bash
NEW_SECRET=$(curl -sf -X POST "$BRAIN/api/v1/nodes/$NODE_ID/rotate-secret" \
  -H "X-Device-Secret: $CURRENT_SECRET" \
  | jq -r .device_secret)
```

### 6. Mint a PAT and use it for automation

```bash
# With a JWT, mint a PAT for your cron job
PAT=$(curl -sf -X POST "$BRAIN/api/v1/api-keys" \
  -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  -d '{"name":"monitoring-cron","expires_at":"2027-01-01T00:00:00Z"}' \
  | jq -r .api_key)

echo "$PAT" > /etc/wg0/monitoring.pat
chmod 600 /etc/wg0/monitoring.pat

# The cron job then uses the PAT the same way it would use a JWT
curl -sf -H "Authorization: Bearer $(cat /etc/wg0/monitoring.pat)" \
  "$BRAIN/api/v1/nodes" | jq '[.[] | {name: .node_name, presence}]'

# List PATs (e.g. for an audit script)
curl -sf -H "Authorization: Bearer $JWT" "$BRAIN/api/v1/api-keys" \
  | jq '[.[] | {name, key_prefix, last_used_at, revoked_at}]'

# Revoke a PAT by id when it's no longer needed
curl -sf -X DELETE -H "Authorization: Bearer $JWT" \
  "$BRAIN/api/v1/api-keys/$KEY_ID"
```

### 7. Use the v2 strict surface

```bash
curl -sf -X POST "$BRAIN/api/v2/devices/$NODE_ID/state" \
  -H "X-Device-Secret: $DEVICE_SECRET" \
  -H "Wg0-Protocol-Version: 2" \
  -H "Content-Type: application/json" \
  -d '{
    "capabilities": ["split_tunnel_linux","byo_exit_linux","peer_observations"],
    "current_state": {
      "endpoint_observed_local": "1.2.3.4:51820",
      "tx_bytes_lifetime": 12345,
      "rx_bytes_lifetime": 67890,
      "route_all_active": false
    }
  }' | jq .desired_state
```

## Common error codes

| HTTP | Meaning |
|---|---|
| 400 | Malformed request body / missing required field |
| 401 | Missing or invalid auth (JWT, device secret, or admin key) |
| 404 | Resource not found or not owned by the authenticated principal |
| 409 | Conflict — e.g. email already registered |
| 422 | Validation error — guardrail hit (e.g. `route_all_traffic=true` on a non-client, missing `Wg0-Protocol-Version` on v2) |

Error bodies look like:
```json
{ "detail": "..." }
```

## Related reading

- [DEVICE_PROTOCOL.md](./DEVICE_PROTOCOL.md) — full v1/v2 spec + migration plan
- [BYO_EXIT.md](./BYO_EXIT.md) — upstream tunnel design note
- [TESTING_ROADMAP.md](./TESTING_ROADMAP.md) — what's shipped and verified
- [ROADBLOCKS.md](./ROADBLOCKS.md) — current product/platform/GTM limitations
- [MARKETING_TAILORS.md](./MARKETING_TAILORS.md) — positioning + ICP (not for docs, for GTM thinking)
