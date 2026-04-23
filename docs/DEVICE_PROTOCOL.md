# wg0 Device Protocol — design note

**Status:** v1 (current behavior) documented + frozen. v2 (formal,
versioned, device-auth) phased rollout in progress.
**Owner:** Scott
**Last revised:** 2026-04-23

## Update 2026-04-23

- Every shell connector + macOS/Windows/Android native app now sends
  an optional `connector_version` string on each heartbeat / v2 state
  report. Stored on `nodes.connector_version`; surfaced in the portal
  so operators can see out-of-date installs at a glance. See the v1
  heartbeat body + v2 state-report fields below.
- Enrollment tokens now support `target_device_id` for portal-driven
  re-enrollment. When present, `enroll_node` takes an UPDATE path on
  the existing `nodes` row (rotating `public_key` + `device_secret`,
  bumping `config_version`, preserving `overlay_ip` and lifetime
  tx/rx counters). If absent or the referenced device is gone, the
  brain falls through to the existing INSERT path. See the
  "Re-enroll flow" subsection below, and
  [ROADBLOCKS.md §15 "2026-04-23 — Re-enroll was creating a new
  node"](ROADBLOCKS.md) for the incident that motivated it.

This doc is the **single source of truth** for everything on the wire
between a wg0 client device and the brain. If you're building a new
client (Linux agent, OpenWrt, macOS menubar, Windows systray, mobile
app), everything you need to implement lives here. Anything not
documented here is *not part of the contract* and may change without
notice.

---

## Why formalize this now

The v1 protocol grew organically out of shell scripts: the connector's
bash heartbeat just POSTed the fields it needed, the brain accepted
them, and we piled on optional fields over time (endpoint, tx/rx,
peers[] in PR2, etc.) without ever saying what shape of request was
expected or what kind of device was on the other end.

That was fine for a single bash implementation. It is **not** fine for
the roadmap's next few steps:

- A Go agent on Linux/OpenWrt (roadmap step 3)
- Native macOS / Windows apps (roadmap step 4)
- A real wg0 mobile app (roadmap step 5)

Each of those needs the protocol to be:

1. **Versioned** — so we can evolve without breaking older clients
2. **Authenticated** — with per-device credentials stronger than a bare
   UUID in the path (the current trust model is "if you know the node_id,
   you ARE the node," which is fine against casual tampering but has
   zero defense against a leaked ID)
3. **Capability-aware** — so the brain can stop shipping fields that a
   client can't act on, and the client can advertise what it *can* do
4. **Desired-state-driven** — the client says "here's my state," the
   brain says "here's what your state *should* be," and the client
   converges. No more implicit ordering of shell commands in the
   heartbeat script.
5. **Honest about device classes** — a stock mobile WireGuard app is
   a peer, not a management agent; the protocol should model that
   explicitly so the brain doesn't keep hoping the Pixel will suddenly
   start heartbeating.

---

## The five pillars

| # | Pillar | What it means in practice |
|---|---|---|
| 1 | Versioning | Every request carries `Wg0-Protocol-Version: 2` (or future N). Server indicates which versions it speaks via the same header on responses. Old v1 endpoints stay wired up indefinitely for backward compatibility. |
| 2 | Stronger device auth | At enrollment, the brain generates and returns a `device_secret` (32 random bytes, urlsafe-base64). The connector stores it alongside the WG private key with the same filesystem permissions. Every protocol call carries `X-Device-Secret: <secret>`. The brain verifies the header matches the row and 401s on mismatch. |
| 3 | Desired state + capabilities | The response from `/state` is an explicit desired-state document: "your peers should look like this, your upstream exit should be in this state, your route-all toggle is this." Clients advertise capabilities in their request (`capabilities: ["split_tunnel", "byo_exit", "same_lan_detection"]`); the brain won't emit state that requires absent capabilities. |
| 4 | Managed vs provisioned | New `device_kind` column on `nodes`. Values: `managed` (runs an agent, heartbeats regularly, accepts desired-state pushes) and `provisioned` (stock WireGuard peer, never heartbeats, only observable via discover/host reports). Brain UIs and presence math already behave differently — this is just making the flag explicit. |
| 5 | Backward compat | v1 endpoints stay alive. v2 endpoints are additive. v2 clients that don't carry `X-Device-Secret` MAY still be allowed in a grace-period window so existing deployments don't brick on the day we ship. After the grace period, v2 endpoints enforce the header; v1 endpoints never require it. |

### Additive rollout note — managed Devices layer (2026-04-15)

The control plane now has a first-class **Device** row above the old
per-network `nodes` membership rows.

- `devices` = one managed connector installation
- `nodes` = one network membership for that installation

This is intentionally **additive**. Existing node-centric APIs continue
to work, and existing single-network installs do not need reenrollment.

What shipped in this phase:

- managed enroll/register accepts and returns a stable
  `installation_id`
- the brain creates a `devices` row for managed connectors and links the
  initial `nodes` row through `nodes.device_id`
- the brain exposes:
  - `GET /api/v1/devices`
  - `GET /api/v1/devices/:device_id`
  - `PATCH /api/v1/devices/:device_id`
  - `POST /api/v1/devices/:device_id/memberships`
  - `PATCH /api/v1/devices/:device_id/memberships/:node_id`
  - `DELETE /api/v1/devices/:device_id/memberships/:node_id`
  - `GET /api/v2/installations/:device_id/state`
  - `POST /api/v2/installations/:device_id/memberships/:request_id/fulfill`
- managed connectors now persist a stable `installation_id` outside the
  per-membership wipe zone and include it in enroll + heartbeat traffic

What is **not** enabled by default yet:

- most clients still run a **single-membership runtime**
- those clients must **not** advertise `multi_membership_v1`
- the UI must keep “attach to another network” gated behind the
  capability until a client can actually run multiple live interfaces

The practical rule is:

**The data model and APIs are multi-membership aware now; runtime
fan-out remains capability-gated until each client family catches up.**

### Membership lifecycle — connector-side checklist

- **Attach to an additional network.** Preflight first
  (`POST /api/v1/devices/:id/memberships/preflight`) so the client can
  surface route conflicts and capability gaps in the user's language.
  Only then POST the actual attach request. The fulfill path creates
  a new `nodes` row and returns a wg-quick config — the existing
  memberships stay up untouched.
- **Detach from one network.**
  `DELETE /api/v1/devices/:id/memberships/:node_id`. The device
  survives, other memberships keep running, the connector's heartbeat
  loop for the remaining memberships continues unchanged.
- **Orphan state.** A device with zero memberships is a valid,
  heartbeating state (not an uninstalled state). Connector UI should
  read "Ready — no network memberships yet" until a new attach lands.
- **Revoke mid-session.** If a subsequent desired-state response omits
  a previously-active membership, tear down its route table before
  its peer entries, to avoid a brief "traffic to dead tunnel" window.
- **Re-enroll of an existing node (shipped 2026-04-23).** Portal-driven
  recovery (app reinstall, lost device_secret, debug-keystore drift)
  mints a single-use token with `target_device_id` pointing at the
  row being repaired. Brain records the target on
  `enrollment_tokens.target_device_id`. On redemption, `enroll_node`
  branches: if `target_device_id` is set AND resolves, the existing
  `nodes` row is updated in place — same `node_id`, same
  `overlay_ip`, rotated `public_key` + `device_secret`, bumped
  `config_version`. If the token's `target_device_id` is unset or the
  target has been deleted, the brain falls through to the existing
  fresh-enroll INSERT path. This is invisible to the shell connectors;
  it matters for portal UX and for the native apps that wipe their
  SecureStorage on reinstall.

Per-connector parity status and milestone plan live in
[CONNECTOR_MULTINETWORK_ROADMAP.md](CONNECTOR_MULTINETWORK_ROADMAP.md).
Full data-model rules live in
[MULTI_NETWORK_INSTALLATION_PLAN.md](MULTI_NETWORK_INSTALLATION_PLAN.md).
Cross-account sharing protocol is in
[SHARED_NETWORK_INVITES.md](SHARED_NETWORK_INVITES.md).

---

## v1 — the current protocol (documented, frozen)

### Endpoints

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/api/v1/enroll/register` | Enrollment token | Connector registers a new device, submits its own WG public key, receives overlay IP + peer list + wg_config template + **device_secret** |
| POST | `/api/v1/networks/:id/provision` | JWT (owner) | Dashboard asks brain to keygen + enroll a new device (QR / mobile flow); brain returns wg_config with `PrivateKey` filled in |
| POST | `/api/v1/nodes/:node_id/heartbeat` | DeviceAuth (X-Device-Secret, v1 grace fallback) | Managed connector pushes telemetry + `peers[]`, pulls peer map + upstream exit state + `config_version` |
| DELETE | `/api/v1/nodes/:node_id/self` | DeviceAuth (v1 grace fallback) | Connector self-unenrolls |
| POST | `/api/v1/nodes/:node_id/rotate-secret` | DeviceAuth (requires CURRENT secret) | Rotate the per-device secret, returns new plaintext once |
| GET | `/api/v1/nodes/:node_id/config` | DeviceAuth (v1 grace fallback) | Fetch a fresh rendered wg_config + `config_version`. Called by the connector when it detects drift via the heartbeat response. |
| GET | `/api/v1/nodes` | JWT (owner) | Dashboard list |
| PATCH | `/api/v1/nodes/:id` | JWT (owner) | Dashboard setting toggles (node_name, route_all_traffic, current_upstream_exit_id) — **mutating fields bump `config_version`** |

### Heartbeat request body (v1)

```json
{
  "endpoint": "24.127.208.189:51820",
  "tx_bytes": 1296354032,
  "rx_bytes": 35799372,
  "connector_version": "linux-shell-0.4.1",
  "peers": [
    {
      "public_key": "i9/OVfl7lrZjA00ANfjjeIoPuIDEMa/yGLH7+mYWDgA=",
      "last_handshake": 1776226000,
      "rx_bytes": 100,
      "tx_bytes": 200
    }
  ]
}
```

All fields optional **except `endpoint`** is expected for same-LAN
detection to work. `peers[]` was added in PR2 and is optional; old
connectors omit it and the brain accepts the omission.
`connector_version` was added 2026-04-22; it's a short identifier
like `linux-shell-0.4.1`, `macos-native-0.2.4`, `windows-native-gg`,
or `android-native-alpha19`. Missing = unknown (old connector). It's
stored on `nodes.connector_version` and drives the portal's "Update
available" pill.

### Heartbeat response (v1)

```json
{
  "overlay_ip": "10.0.0.3/32",
  "peers": [
    { "public_key": "...", "allowed_ips": "10.0.0.2/32, 10.0.0.0/24",
      "endpoint": "24.127.208.189:51820", "is_online": true,
      "on_same_lan": false }
  ],
  "upstream_exit": {
    "id": "uuid",
    "name": "Mullvad SE",
    "provider_type": "mullvad",
    "wg_config": "..."
  }
}
```

The connector does implicit desired-state convergence:
- Calls `wg set` for each peer (add/update endpoint, allowed_ips)
- Installs kernel routes for each peer's allowed_ips
- If `upstream_exit` is present and different from the stored state,
  brings up `wg0-up`
- If `upstream_exit` is absent and `wg0-up` is up, brings it down
- Same-LAN aliasing / unaliasing based on `on_same_lan` flag
- Route-all install/teardown based on `0.0.0.0/0` in any peer's allowed_ips

None of this is documented in the v1 response — the connector "just
knows." v2 will flip it so the brain **says** what state is desired.

### v1 trust model

A device's identity is the `node_id` UUID. Anyone who learns that UUID
can POST heartbeats and DELETE the node — 122 bits of entropy is plenty
against guessing, but **has zero defense against credential leaks**
(logs, backups, screen shares, etc.). v2's `device_secret` is the fix.

---

## v2 — the spec (SHIPPED in P2, see the `shipped` column above)

### Versioning

Every v2 request MUST send:

```
Wg0-Protocol-Version: 2
```

The brain responds with:

```
Wg0-Protocol-Version: 2
Wg0-Protocol-Supported: 1,2
```

Clients that don't send the header are assumed to be v1 and routed to
the legacy handlers. This is the backward-compat escape hatch.

### Authentication: `device_secret`

At enrollment time (both `register` and `provision` flows), the brain
generates a 32-byte random value, urlsafe-base64-encodes it, and:

1. Stores the **hash** in `nodes.device_secret_hash` (not the plaintext —
   see "secret handling" below).
2. Returns the plaintext to the caller **once**, in the enrollment
   response body (field name: `device_secret`).
3. For `register` (shell connector path): the connector writes the
   secret to `${KEY_DIR}/device_secret` with mode 0600 next to
   `privatekey`.
4. For `provision` (dashboard QR path): the secret is currently
   **not** needed because QR devices never heartbeat. We'll still
   generate one in case they ever do (e.g., wg0 mobile app in roadmap
   step 5), but it's not returned in the user-visible QR wg_config.

Every v2 protocol call MUST carry:

```
X-Device-Secret: <urlsafe-b64>
```

The brain looks up the node by `node_id` (from the URL), hashes the
received secret, compares constant-time against the stored hash, and
401s on mismatch.

**Secret handling:**
- Store in DB as a hash (Argon2id or bcrypt — match what's used for
  account passwords). Plaintext is transmitted once and not persisted.
- Rate-limit failed auth attempts per node_id to block brute-force.
- Rotation: add `POST /api/v2/devices/:id/rotate-secret` that requires
  the **old** secret, returns a new one. Tracked as future work.

**Grace period:** v1 endpoints continue to accept plain-UUID auth.
v2 endpoints MAY accept the plain UUID during a documented transition
window (default: 30 days after first device enrolls with a secret).
After that, v2 is strict.

### Capabilities

Every v2 client sends its capabilities in the heartbeat body:

```json
{
  "capabilities": [
    "split_tunnel_linux",
    "byo_exit_linux",
    "same_lan_detection",
    "peer_observations",
    "desired_state_convergence"
  ]
}
```

Capability strings are stable identifiers. When the brain emits
desired-state, it MUST NOT include fields that require absent
capabilities. Example: don't ship an `upstream_exit` to a Windows host
until `byo_exit_windows` exists.

Known capabilities (v2.0):

| Capability | Added | Meaning |
|---|---|---|
| `same_lan_detection` | v1 (implicit) | Connector handles `on_same_lan` on peers — aliases/unaliases the overlay IP |
| `split_tunnel_linux` | v1 (implicit) | Connector installs `/1` routes + endpoint exception when 0.0.0.0/0 appears in a peer's allowed_ips |
| `split_tunnel_macos` | v1 (implicit) | Same, macOS variant without `ip rule` |
| `byo_exit_linux` | v1 (implicit) | Connector runs the `wg-quick up wg0-up` state machine for upstream exits |
| `byo_exit_macos` | v1 (implicit) | Same, macOS variant — relies on discover for inbound reachability |
| `peer_observations` | PR2 | Connector parses `wg show dump` and reports per-peer handshakes |
| `desired_state_convergence` | v2 (new) | Connector understands the v2 desired-state response shape and applies it atomically |

### Device kinds

New column `nodes.device_kind TEXT NOT NULL DEFAULT 'managed'`, check
constraint `IN ('managed', 'provisioned')`.

| Kind | Heartbeats? | Telemetry source | Trust model |
|---|---|---|---|
| `managed` | Yes, every ~30s | `last_seen` from heartbeat, discover, host reports | v1: node_id. v2: device_secret. |
| `provisioned` | No — stock WG peer | discover only (host reports catch raw peers) | n/a — provisioned devices don't make protocol calls |

`device_kind` is set:
- `managed` when the `register` endpoint is hit (shell connector path)
- `provisioned` when the `provision` endpoint is hit (dashboard QR flow)

Brain behavior based on kind:
- `provisioned` devices skip the "it used to heartbeat so it's Offline" state — they go straight Unknown → Observed → Unknown.
- `provisioned` devices never get an `upstream_exit` block, even if the dashboard accidentally tries to push one (guardrail in PATCH).
- Admin UI shows a different icon + tooltip for provisioned devices so support doesn't keep asking "why isn't this Mac connector running."

### Desired-state response (v2)

Replaces the implicit "do whatever the connector happens to understand"
convergence with an explicit document:

```json
{
  "node_id": "af1e321f-...",
  "overlay_ip": "10.0.0.3/32",
  "network_type": "native",
  "desired_state": {
    "peers": [
      {
        "public_key": "...",
        "allowed_ips": ["10.0.0.2/32", "10.0.0.0/24"],
        "endpoint": "24.127.208.189:1085",
        "persistent_keepalive": 25,
        "on_same_lan": false
      }
    ],
    "upstream_exit": {
      "state": "active",
      "id": "uuid",
      "wg_config": "..."
    },
    "route_all_traffic": false
  },
  "server_time": "2026-04-10T21:30:00Z",
  "supported_capabilities_required": ["peer_observations"]
}
```

The client:
1. Computes the diff against its current state
2. Applies idempotent convergence operations in a documented order:
   a. `wg set` peers (add/update/remove)
   b. Install/update routes
   c. Apply same-LAN aliasing
   d. Apply upstream exit state
   e. Apply route-all state
3. Reports any convergence failures back on the next heartbeat
   via a new `last_convergence_errors: []` field

### Managed-device state report (v2)

The v2 heartbeat body fully specifies what the device currently sees:

```json
{
  "protocol_version": 2,
  "device_kind": "managed",
  "capabilities": ["same_lan_detection", "split_tunnel_macos", "peer_observations"],
  "connector_version": "macos-native-0.2.4",
  "current_state": {
    "endpoint_observed_local": "24.127.208.189:51820",
    "wg_interface": "wg0",
    "wg_listen_port": 51820,
    "tx_bytes_lifetime": 1296354032,
    "rx_bytes_lifetime": 35799372,
    "peers": [
      { "public_key": "...", "last_handshake": 1776226000,
        "rx_bytes": 100, "tx_bytes": 200, "endpoint_seen": "1.2.3.4:5678" }
    ],
    "upstream_exit_active_id": null,
    "route_all_active": false,
    "last_convergence_errors": []
  }
}
```

`connector_version` is an optional top-level string (added
2026-04-22). Same semantics as the v1 field — see above. Brain
behavior is identical for v1 and v2 reports.

### Errors

v2 responses use standard HTTP status codes. Error bodies are:

```json
{
  "error": {
    "code": "device_secret_mismatch",
    "message": "Provided X-Device-Secret does not match the enrolled device",
    "retry_after_seconds": 30
  }
}
```

Documented error codes:
- `device_not_found` (404)
- `device_secret_missing` (401)
- `device_secret_mismatch` (401) — with rate-limit backoff via `retry_after_seconds`
- `protocol_version_unsupported` (400)
- `capability_required` (409) — brain won't push state the client can't act on, but it happened anyway
- `network_not_found` (404)
- `validation` (422) — body schema mismatch with `field: string` detail

---

## Migration plan

| Phase | What ships | Backward compat |
|---|---|---|
| **P1 — auth foundation (shipped)** | `device_secret_hash` column, enrollment generates + returns plaintext once, connector stores it, `X-Device-Secret` extractor with v1 fallback, `device_kind` column populated on enroll + provision | Old connectors keep working — v1 endpoints ignore the new header. New connectors get the secret but v1 endpoints still don't require it. |
| **P1.1 — rotate + refresh (shipped)** | `POST /api/v1/nodes/:id/rotate-secret` with current-secret auth; `GET /api/v1/nodes/:id/config` returning fresh wg_config text; `config_version` column on nodes + heartbeat response; connector drift detection with `wg syncconf`; presence promotion when a managed host reports a fresh peer handshake | Fully backward compatible. New connectors read `config_version` from heartbeats; old connectors just ignore the field. |
| **P2 — v2 surface (shipped)** | `POST /api/v2/devices/:id/state` + `GET /api/v2/devices/:id/state` with strict auth (no grace fallback), `Wg0-Protocol-Version: 2` header required, explicit `capabilities: [...]` list, explicit `desired_state` response document (peers + upstream_exit state enum + route_all_traffic). Smoke-tested in prod. | Additive — v1 endpoints keep working. Nothing in the shell connector path uses v2 yet. The Go agent (roadmap step 3) will be the first v2 client. |
| **P2 — v2 endpoints** | `POST /api/v2/devices/:id/state` (the v2 heartbeat replacement). v2 strict on `X-Device-Secret`. Capabilities list required. | v1 `/heartbeat` keeps working indefinitely. |
| **P3 — desired-state convergence** | Formal `desired_state` response shape. Connector rewritten (Go agent likely) to consume it. v1 shell connector stays on v1 endpoints. | n/a — Go agent is a separate client. |
| **P4 — grace period end** | v2 endpoints drop the "accept v1 fallback" path. Any deployment still using v1 falls back to v1 endpoints or must upgrade. | v1 endpoints still exist. |
| **P5 — provisioned device lifecycle** | Admin UI surfaces `device_kind` visually. Presence model uses `device_kind` to skip Offline state for provisioned devices. | n/a |

---

## Open questions

- **Should we sign requests with the WireGuard private key?** More
  elegant than a separate secret but drags in Curve25519 signing
  awkwardness (x25519 is a DH key, not a signing key). The
  `device_secret` approach is boring but unambiguously correct.
- **Bulk / delta responses?** For networks with 1000+ peers, shipping
  the full peer list every 30s is wasteful. Phase 3-ish.
- **Push vs poll?** A long-poll or websocket channel would let the
  brain push desired-state updates instantly (route-all toggle, for
  example) instead of waiting for the next 30s heartbeat. Definitely
  post-v2.
- **Rotation UX.** If a device's secret leaks, today there's no way to
  rotate without fully re-enrolling. Phase 2-ish.

---

## Anti-goals

- **A full RPC framework.** No gRPC, no Protobuf, no code generation.
  JSON over HTTPS is plenty. The boundary is small enough that schema
  drift is caught by Rust types on the server and TypeScript types on
  the dashboard, and connectors handle their own parsing.
- **End-to-end encryption of the protocol payload itself.** HTTPS is
  already the crypto boundary. The content doesn't need another layer.
- **Feature parity across every client.** Different clients will
  expose different capability sets. The brain must not assume one
  client implements everything the reference connector does.
