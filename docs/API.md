# wg0 API — human-friendly reference

**Machine-readable spec:** [openapi.yaml](./openapi.yaml)  
**Agents index:** [llms.txt](./llms.txt)

Production base URL: `https://connect.wg0.io`  
Local dev base URL: `http://localhost:8000`

## Mental model

wg0 is now **device-first**.

- A **device** is one managed installation of the software.
- A **node** is that device's membership inside one network.
- A managed device can expose:
  - endpoint history
  - mesh / peering state
  - relay-helper state
  - membership-scoped settings like role, advertised routes, and VPN-through-host

Older node-centric endpoints still work and remain important for connector compatibility, but the dashboard's managed-device workflows now live under `/api/v1/devices/...`.

## Authentication cheat sheet

| Header / field | Scheme | Used by |
|---|---|---|
| `Authorization: Bearer <JWT>` | `bearerAuth` | human-owner/admin/dashboard requests |
| `Authorization: Bearer wg0_pat_...` | `bearerAuth` (PAT variant) | long-lived automation / MSP tooling / MCP |
| `X-Device-Secret: <secret>` | `deviceSecret` | v1 device-authenticated endpoints |
| `X-Device-Secret` + `Wg0-Protocol-Version: 2` | `strictDeviceAuth` | strict v2 device and installation endpoints |
| `X-Admin-Key: <key>` | `adminKey` | `/api/v1/admin/*` |
| `token` field in request body | `enrollmentToken` | `POST /api/v1/enroll/register` only |

## Public endpoint map

### Auth
- `POST /api/v1/auth/register` — create account, returns JWT
- `POST /api/v1/auth/login` — exchange credentials for JWT
- `POST /api/v1/auth/accept-invite` — accept an invited membership

### API keys (personal access tokens) — JWT-only
- `POST /api/v1/api-keys`
- `GET /api/v1/api-keys`
- `DELETE /api/v1/api-keys/:id`

PATs are accepted anywhere a normal bearer JWT is accepted, except on PAT-management endpoints themselves.

### Accounts, memberships, and team management
- `GET /api/v1/accounts/me` — current account + role context
- `GET /api/v1/accounts/me/memberships` — all account memberships for the caller
- `POST /api/v1/accounts/switch` — switch active account context
- `GET /api/v1/accounts/users` — list account users
- `POST /api/v1/accounts/users/invite` — invite a user
- `DELETE /api/v1/accounts/users/invite/:id` — revoke a pending invite
- `POST /api/v1/accounts/users/:id/suspend`
- `POST /api/v1/accounts/users/:id/reactivate`
- `DELETE /api/v1/accounts/users/:id`
- `PATCH /api/v1/accounts/users/:id`
- `GET /api/v1/accounts/users/:id/scopes`
- `POST /api/v1/accounts/users/:id/scopes`
- `DELETE /api/v1/accounts/users/:id/scopes/:network_id`

### Device profiles and self-service access
- `GET /api/v1/accounts/device-profiles`
- `POST /api/v1/accounts/device-profiles`
- `PATCH /api/v1/accounts/device-profiles/:id`
- `DELETE /api/v1/accounts/device-profiles/:id`
- `GET /api/v1/accounts/device-profiles/:id/users`
- `POST /api/v1/accounts/device-profiles/:id/users`
- `DELETE /api/v1/accounts/device-profiles/:id/users/:user_id`
- `GET /api/v1/my-access` — current member self-service view
- `POST /api/v1/my-access/:id/enroll-token`
- `POST /api/v1/my-access/:id/provision`
- `PATCH /api/v1/my-access/nodes/:id` — self-service rename / VPN toggle / delete actions
- `PATCH /api/v1/nodes/:id/assign` — admin ownership assignment
- `POST /api/v1/nodes/:id/claim` — self-claim via device secret

### Networks
- `GET /api/v1/networks` — list networks with aggregate counts
- `POST /api/v1/networks` — create overlay or native-LAN network
- `PATCH /api/v1/networks/:id` — update mutable network policy
- `DELETE /api/v1/networks/:id`
- `POST /api/v1/networks/:id/provision` — QR/mobile provisioning flow
- `GET /api/v1/networks/:id/traffic`

Important network fields:
- `network_type`: `overlay` or `native`
- `relay_mode`: `never`, `auto`, or `always`

`relay_mode` now applies to **both overlay and native networks**. On native networks it can assist client-to-host bootstrap when direct peering is degraded or slow to establish.

### Devices — managed installation surface
- `GET /api/v1/devices` — list managed devices
- `GET /api/v1/devices/:id` — device detail
- `PATCH /api/v1/devices/:id` — update device metadata, including `collect_device_telemetry`
- `GET /api/v1/devices/:id/endpoint-history` — device-scoped endpoint timeline
- `GET /api/v1/devices/:id/peerings` — device mesh / relay-helper view
- `POST /api/v1/devices/:id/memberships` — request attach to another network
- `PATCH /api/v1/devices/:id/memberships/:node_id` — update one membership
- `DELETE /api/v1/devices/:id/memberships/:node_id` — remove one membership

This is the permanent control-plane home for:
- memberships (including multi-network: one device can hold many
  active `(device_id, node_id)` pairs)
- endpoint history
- peerings / relay state
- device-level VPN-through-host control at the membership level
- optional stored device telemetry:
  - `collect_device_telemetry`
  - `latest_device_telemetry`
  - `telemetry_updated_at`

Multi-network flow, end-to-end:

1. `POST /api/v1/devices/:id/memberships/preflight` — check for route
   conflicts / missing capabilities before committing.
2. `POST /api/v1/devices/:id/memberships` — request attach; brain
   creates a `device_membership_requests` row.
3. `POST /api/v2/installations/:id/memberships/:request_id/fulfill`
   — connector submits public_key + os_type; brain allocates IP,
   creates the `nodes` row, returns the wg-quick config.
4. `DELETE /api/v1/devices/:id/memberships/:node_id` — detach from
   one network; device stays alive + other memberships untouched.

See [MULTI_NETWORK_INSTALLATION_PLAN.md](MULTI_NETWORK_INSTALLATION_PLAN.md)
for the full design and [CONNECTOR_MULTINETWORK_ROADMAP.md](CONNECTOR_MULTINETWORK_ROADMAP.md)
for per-connector support status.

### Enrollment
- `POST /api/v1/enroll/generate-token`
- `POST /api/v1/enroll/register`
- `POST /api/v1/networks/:id/provision`

Managed enrollments now return `device_id` and `installation_id` in addition to the node membership identity.

### Nodes — compatibility and owner surface
- `GET /api/v1/nodes`
- `PATCH /api/v1/nodes/:id`
- `DELETE /api/v1/nodes/:id`
- `DELETE /api/v1/nodes/:id/self`
- `GET /api/v1/nodes/:id/endpoint-history`

This is still the live compatibility path for:
- connector updates
- older tooling
- membership-scoped owner actions

### Device protocol v1 (device-authenticated)
- `POST /api/v1/nodes/:id/heartbeat`
- `GET /api/v1/nodes/:id/config`
- `POST /api/v1/nodes/:id/rotate-secret`
- `DELETE /api/v1/nodes/:id/self`

The v1 heartbeat now carries newer optional fields too:
- `installation_id`
- `capabilities`
- `host_lan_ip`
- `upstream_exit_health`
- `route_all_active`
- `telemetry`

### Device protocol v2 (strict)
- `POST /api/v2/devices/:id/state`
- `GET /api/v2/devices/:id/state`
- `PATCH /api/v2/devices/:id/settings`
- `GET /api/v2/installations/:id/state`
- `POST /api/v2/installations/:id/memberships/:request_id/fulfill`

The v2 state surface also carries optional `telemetry`, and both
device/install responses can return:
- `collect_device_telemetry`
- `latest_device_telemetry`
- `telemetry_updated_at`

Use this surface for:
- strict versioned device state
- desired-state convergence
- device-side VPN toggle (`route_all_traffic`)
- multi-membership fulfillment — one device, many networks, one
  heartbeat loop per membership

### Shared networks

Networks can be shared across account boundaries via invites. A guest
connector sees and heartbeats on a shared network the same way it
would on an owned one; the difference is entirely at enrollment time.

- `POST /api/v1/networks/:id/shared-invites` — owner/admin mints an
  invite (email-based, 7-day expiry).
- `GET /api/v1/shared-network-access` — list shared networks the
  current user is a member of.
- `POST /api/v1/auth/accept-shared-invite` — invitee accepts with
  token (creates a free account if they don't have one).
- `POST /api/v1/shared-networks/:membership_id/enroll-token` — guest
  mints a single-use enrollment token scoped to that shared network;
  the connector then calls `/api/v1/enroll/register` with it and gets
  a full device-secret + wg config back.
- `DELETE /api/v1/shared-network-memberships/:id` — inviter or
  invitee revokes.

Full flow in [SHARED_NETWORK_INVITES.md](SHARED_NETWORK_INVITES.md).

### BYO Exit
- `GET /api/v1/nodes/:id/upstream-exits`
- `POST /api/v1/nodes/:id/upstream-exits`
- `DELETE /api/v1/upstream-exits/:id`

This is host-side upstream egress. It is separate from relay assist:
- **BYO Exit** = where internet egress happens
- **Relay assist** = how peers reach each other when direct peering is degraded

### Billing
- `GET /api/v1/billing/status`
- `POST /api/v1/billing/checkout-session`
- `POST /api/v1/billing/portal-session`
- `POST /api/v1/billing/webhook`
- `POST /api/v1/billing/remediate`

### Traffic
- `GET /api/v1/nodes/:id/traffic`
- `GET /api/v1/networks/:id/traffic`

### Admin
- `GET /api/v1/admin/stats`
- `GET /api/v1/admin/accounts`
- `GET /api/v1/admin/accounts/:id`
- `DELETE /api/v1/admin/accounts/:id`
- `GET /api/v1/admin/nodes`
- `GET /api/v1/admin/networks`
- `GET /api/v1/admin/traffic`

### Health
- `GET /health`

## Relay assist notes

Relay assist is shipped. It is not a public browsing exit.

- A relay can help managed peers reach each other when direct peer-to-peer is degraded.
- On native networks, this can temporarily assist client-to-host reachability while NAT/firewall state settles.
- If a client is in VPN-through-host mode, internet egress still happens on the **host node** or its configured BYO Exit, not from the relay's public IP.

The dedicated relay-orchestrator service is an **internal** control-plane service and is intentionally documented separately from the public brain API.

## Common task recipes

### 1. Create a native network with relay assist left at default

```bash
BRAIN=https://connect.wg0.io

TOKEN=$(curl -sf -X POST "$BRAIN/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"email":"ops@example.com","password":"correct horse battery staple"}' \
  | jq -r .access_token)

curl -sf -X POST "$BRAIN/api/v1/networks" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name":"Office LAN",
    "network_type":"native",
    "native_gateway_subnet":"10.255.16.0/24",
    "native_host_tunnel_ip":"10.255.16.70",
    "native_client_start":"10.255.16.200",
    "native_client_end":"10.255.16.220"
  }'
```

### 2. Change a network's relay mode

```bash
curl -sf -X PATCH "$BRAIN/api/v1/networks/$NET_ID" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"relay_mode":"auto"}'
```

Use:
- `never` for direct-only
- `auto` for relay assist during degraded bootstrap/recovery
- `always` to force managed peerings through the dedicated relay

### 3. List managed devices and inspect peerings

```bash
DEVICE_ID=$(curl -sf -H "Authorization: Bearer $TOKEN" \
  "$BRAIN/api/v1/devices" | jq -r '.[0].id')

curl -sf -H "Authorization: Bearer $TOKEN" \
  "$BRAIN/api/v1/devices/$DEVICE_ID/peerings" | jq .
```

### 4. Toggle VPN-through-host from the strict device surface

```bash
curl -sf -X PATCH "$BRAIN/api/v2/devices/$NODE_ID/settings" \
  -H "X-Device-Secret: $DEVICE_SECRET" \
  -H "Wg0-Protocol-Version: 2" \
  -H "Content-Type: application/json" \
  -d '{"route_all_traffic":true}' | jq .
```

### 5. Poll installation state for pending membership requests

```bash
curl -sf "$BRAIN/api/v2/installations/$DEVICE_ID/state" \
  -H "X-Device-Secret: $DEVICE_SECRET" \
  -H "Wg0-Protocol-Version: 2" | jq .
```

### 6. Fulfill an additional network membership from an upgraded client

```bash
PRIV=$(wg genkey)
PUB=$(echo "$PRIV" | wg pubkey)

curl -sf -X POST \
  "$BRAIN/api/v2/installations/$DEVICE_ID/memberships/$REQUEST_ID/fulfill" \
  -H "X-Device-Secret: $DEVICE_SECRET" \
  -H "Wg0-Protocol-Version: 2" \
  -H "Content-Type: application/json" \
  -d "{\"public_key\":\"$PUB\"}" | jq .
```

## Common error codes

| HTTP | Meaning |
|---|---|
| 400 | Malformed request body / missing required field |
| 401 | Missing or invalid auth |
| 404 | Resource not found or not owned by the authenticated principal |
| 409 | Conflict |
| 422 | Validation / guardrail error |

Error bodies look like:

```json
{ "detail": "..." }
```

## Related reading

- [DEVICE_PROTOCOL.md](./DEVICE_PROTOCOL.md)
- [BYO_EXIT.md](./BYO_EXIT.md)
- [TESTING_ROADMAP.md](./TESTING_ROADMAP.md)
- [ROADBLOCKS.md](./ROADBLOCKS.md)
