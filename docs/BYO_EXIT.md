# Bring Your Own Exit — design note

**Status:** Phase 1 shipped (per-host exit selection + host/macOS connector state machines). Phase 2/3/4 still planning.
**Owner:** Scott
**Last revised:** 2026-04-10 (Phase 1 ship)

This is the design-time thinking behind letting wg0 customers pick
which public IP their traffic egresses from — home WAN, Mullvad LA,
Mullvad London, or whatever else they subscribe to — without wg0
itself ever carrying the traffic. This note is the canonical mental
model for the feature. Read it before writing code.

---

## The three statements to carry forward

Everything else in this doc is elaboration on these three rules.
If any PR or design discussion violates them, push back.

1. **v1 is host-upstream, period.** The host node is the only thing
   that actually talks to the provider (Mullvad, Proton, whatever).
   All other wg0 clients route through the host and inherit its exit.
   Direct-client-upstream is not v1; it's phase 4+ at best, and
   honestly may never ship.

2. **One provider profile belongs to one host, not many devices.**
   WireGuard peers are keyed by public key. If the same provider
   keypair is installed on multiple devices that are simultaneously
   active, the provider sees one peer with a flapping endpoint and
   things break in confusing ways. The right mental model is:

   > *A single upstream provider profile on the host can serve
   > multiple downstream wg0 clients behind that host, subject to
   > provider terms, host bandwidth, and host reliability.*

   Use that sentence in the docs. Never say "unlimited devices."

3. **Control plane, not data plane.** The brain stores and
   orchestrates the provider config. The host runs the actual
   upstream tunnel. The moment wg0 cloud terminates a customer's
   Mullvad session, we've become a different company with different
   problems (bandwidth, abuse handling, compliance, the works).

---

## The core mental model

A provider's WireGuard config is one identity: one keypair, one peer
record on the provider side. That's non-negotiable — it's how the
protocol works.

So the asymmetry is:

| Configuration                                               | Provider sees  | Works?                            |
|-------------------------------------------------------------|----------------|-----------------------------------|
| 1 host runs the profile, N wg0 clients behind it            | 1 peer         | ✅ clean                           |
| Same profile copied to N devices, all active                | 1 flapping peer | ❌ traffic goes to last endpoint   |
| N devices each with their own provider profile              | N peers        | ✅ but N provider slots/licenses   |

Row 1 is the product. Row 3 is "direct client upstream" — later,
maybe never.

---

## Already possible today (Phase 0)

The "hidden version" of this feature is shipped as of the route-all
VPN release. It requires zero new wg0 code and zero new infrastructure.

Walk-through:

1. Jason (the native-LAN host node) installs WireGuard on his Mac
   and imports his personal Mullvad config — the same `.conf` file
   you download from Mullvad's portal
2. Jason runs `sudo wg-quick up mullvad-la`. His Mac's default
   route is now the Mullvad tunnel; his public IP becomes the
   Mullvad LA exit IP
3. On the wg0 dashboard, Scott (a native-LAN client on Jason's
   network) gets `route_all_traffic=true` toggled on
4. Within 30 seconds, Scott's connector sees the new peer map
   (allowed_ips=0.0.0.0/0 for Jason), installs the split-tunnel
   `/1` routes, and all of Scott's internet traffic starts going
   `scott → wg0 → jason → mullvad → internet`
5. `curl ifconfig.me` on Scott now returns the Mullvad LA IP.
   Scott can still ping `10.0.0.2` (Jason) over the LAN
   simultaneously. Scott did not buy a Mullvad subscription.

This is the entire pitch. Everything above the "already possible
today" line is just making it nicer and more discoverable.

### Phase 0 deliverable: a docs page that says exactly this

No code. Just framing. Tell existing customers the hidden feature
already works — it's the cheapest conversion we can do.

---

## Phase 1: Managed Bring Your Own Exit (v1 of the real product)

Minimum viable managed version. Single exit per host, one upstream
tunnel at a time, host-level selection.

### New brain resources

A new table `upstream_exits`:

```sql
CREATE TABLE upstream_exits (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id      UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,         -- "Mullvad LA", "Mullvad London", etc.
    provider_type   TEXT NOT NULL,         -- "mullvad" | "proton" | "custom-wg"
    wg_config       TEXT NOT NULL,         -- encrypted; decrypted only when pushed to host
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
```

A new column on `nodes`:

```sql
ALTER TABLE nodes ADD COLUMN
    current_upstream_exit_id UUID REFERENCES upstream_exits(id) ON DELETE SET NULL;
```

`current_upstream_exit_id` is non-null only for native-LAN host nodes
that have been assigned an exit.

### New API endpoints

- `POST   /api/v1/upstream-exits`         — upload a provider wg config
- `GET    /api/v1/upstream-exits`         — list (no wg_config in response; just id + name + provider_type)
- `DELETE /api/v1/upstream-exits/:id`
- `PATCH  /api/v1/nodes/:id`              — extend with `current_upstream_exit_id` field (or null for "home WAN")
- `GET    /api/v1/nodes/:id/upstream-config` — host-only pull of the decrypted wg config (authenticated by node_id, the same way heartbeats are)

### Host connector changes

A new `upstream` subcommand on the connector (or a new section in the
heartbeat loop):

1. On heartbeat, the brain tells the host which `upstream_exit_id`
   should be active (null = home WAN)
2. Host fetches the decrypted wg_config from the brain, stores it as
   `/etc/wireguard/wg0-up.conf`
3. If the desired exit differs from the currently-active one:
   - `wg-quick down wg0-up` (if anything is currently up)
   - `wg-quick up wg0-up` (if a new exit is desired)
4. Install the policy-routing exception so the host's own wg0
   listener stays reachable (see **Known engineering problems** §1)
5. Push MTU + DNS to downstream clients via the existing peer map

### Dashboard UX

Inside a native-LAN network's expanded view:

```
Host: home-host (Jason)
Upstream exit: [ Home WAN ▾ ]    ⬤ Active  last handshake 4s ago
                ┌──────────────┐
                │ Home WAN     │
                │ Mullvad LA   │
                │ Mullvad London│
                └──────────────┘
```

Three small state indicators next to the dropdown:

- **Configured** — what the brain thinks the host should be running
- **Active** — what the host is actually running (heartbeat-reported)
- **Healthy** — most recent provider handshake < 3 minutes ago

"Configured" can get out of sync with "Active" during a switchover
or when a provider tunnel is flapping. Showing both tells the truth
instead of pretending it's one state.

Phase 1 is deliberately ugly on this last point: no automatic retry,
no health-check scheduling, no fail-over. If the provider tunnel
drops, the host is responsible for reconnecting on its own
(`wg-quick` handles this in most cases).

---

## Phase 2: Switching / multiple stored exits per host

- Store N configs per host, only one active at a time
- Dashboard: switch between them without re-uploading
- All route-all clients on the host flip simultaneously — there's
  still only one active upstream tunnel

This is mostly a UX improvement on Phase 1. Zero new networking
complexity.

---

## Phase 3: Multiple simultaneous exits on one host

This is where it gets hard. If Scott wants LA and Sarah wants London
at the same time, and they're both downstream of the same host:

- Host runs multiple upstream tunnels concurrently (`wg0-up-la`,
  `wg0-up-london`)
- Per-downstream-client policy routing: each downstream client gets
  an `iptables` fwmark on its overlay /32, and a corresponding
  `ip rule fwmark X lookup Y` steers its traffic into the right
  upstream tunnel
- Per-exit NAT rules (`MASQUERADE` on the correct upstream interface)
- Per-exit MTU pinning on the downstream client config
- Per-exit DNS push

This is doable on Linux with standard tools. On macOS it's harder —
no `fwmark`, policy routing is clunkier, `pf` can do it but the
configuration syntax is painful.

I would not touch phase 3 until phase 1 has been running in
production for at least a quarter and there's real customer demand
for it. It's the cool party trick; it is not the v1 win.

---

## Phase 4: Direct client upstream

Each client device runs its own provider tunnel alongside wg0.
Requires one provider device slot per client. The main reason to
build this is if a customer wants their phone to egress via Mullvad
independently of the home network (e.g. while on cellular, not
going through the home host at all).

Stock WireGuard mobile apps already support multiple tunnels side by
side. This phase is mostly a portal-level feature: store each
client's provider profile, make the dashboard hand out the right
one. No new routing logic.

Worth noting: once a true wg0 mobile client exists (phase 5 of the
main wg0 roadmap), direct client upstream becomes a much more
natural feature — the native app can manage both tunnels in one UI.

---

## Known engineering problems (these WILL bite)

### 1. Host-reachability policy routing

When the host brings up `wg-quick up wg0-up` with `AllowedIPs = 0.0.0.0/0`,
wg-quick replaces the default route with the upstream tunnel. Now:

- Scott, on cellular, tries to connect to Jason's wg0 on UDP 51820
- Packet arrives on Jason's eth0 from the internet, hits wg0 listener
- Jason's kernel responds from wg0's listen port
- Default route is the **upstream tunnel**, so the reply goes out
  via Mullvad instead of the original ISP
- Scott never receives it — Mullvad is NAT'ing the reply with the
  wrong source

Fix (Linux): fwmark the wg0 listener's reply packets and route them
via a secondary routing table whose default route is still the
original ISP.

```bash
# Tag packets sourced from UDP 51820
iptables -t mangle -A OUTPUT -p udp --sport 51820 -j MARK --set-mark 0x100

# Secondary table with the original default route
echo "100 wg0-listener" >> /etc/iproute2/rt_tables
ip route add default via $ORIG_GATEWAY dev $ORIG_IFACE table wg0-listener

# Steer marked packets via the secondary table
ip rule add fwmark 0x100 lookup wg0-listener
```

On macOS the Linux `ip rule` / `iptables mangle` chain has no clean
equivalent, and we are deliberately **not** asking customers to set up
router port forwarding — that's the one thing the product is trying
to eliminate. The path we've field-tested on macOS instead uses the
**discover sidecar as the reachability anchor** when the upstream
tunnel is active:

1. Host brings up `wg-quick up wg0-up` (Mullvad). The default route
   becomes the upstream tunnel.
2. Host's wg0 listener stays bound to UDP 51820 on all interfaces.
3. The host's connector heartbeats, and its own wg0 keepalive packets
   (sent to the discover sidecar every 25s via `PersistentKeepalive`)
   now get routed out via `wg0-up` → Mullvad. Mullvad's NAT allocates
   an outbound mapping (`MullvadExitIP:randomPort → peer`) and the
   discover sidecar records the host's real post-NAT source address.
4. On the brain's next heartbeat tick every peer learns the host's
   new endpoint — the Mullvad one — and starts sending to it.
5. Peer packets arrive at `MullvadExitIP:randomPort`, Mullvad's NAT
   has a matching outbound mapping, they're forwarded back down the
   upstream tunnel to the host's wg0 listener, and the reply path
   inherits the same mapping on the way out. No second listener,
   no `ip rule`, no router configuration.
6. `PersistentKeepalive = 25` on every peer is load-bearing: it
   refreshes the Mullvad NAT mapping every 25 seconds so the hole
   never closes. This is already set in the brain's generated
   configs via `render_peer_blocks`.

**Verified in our tested setup** (Mullvad + a macOS Sonoma/Sequoia
host behind consumer NAT) — we use this for day-to-day development.
It depends on the upstream provider's NAT being friendly to UDP
source-port preservation, which Mullvad is. More hostile providers
(symmetric CGNAT on top of Mullvad, for example) may still need a
Linux host with the `ip rule` path, which is why we still document
and ship the Linux fwmark solution above.

Future direction: ship a matching `pf` rdr-anchor + rtable setup on
macOS as a belt-and-braces backup, so the fallback doesn't depend
on discover being healthy. Tracked alongside Phase 2/3 work.

### 2. DNS behavior + leaks

If Scott's Mac still uses `1.1.1.1` directly when route-all is on,
his DNS lookups happen via the normal resolver path. His exit IP
is hidden but his ISP can still see every domain he visits.

Options:
- **Simplest:** push `DNS = <provider DNS IP>` in the wg0.conf we
  give the downstream client. The provider's DNS IP is reachable
  inside the upstream tunnel, so lookups go through Mullvad.
- **Nicer:** run a tiny resolver on the host that forwards upstream
  and push the host's overlay IP as the DNS server. Gives us
  caching + a single egress point, but adds a moving part.

Phase 1 should do the simple version.

### 3. MTU stacking

Client wg0 (60 bytes) + host Mullvad wg0 (60 bytes) = ~120 bytes of
tunnel overhead on top of a 1500-byte Ethernet MTU. Effective MTU
for the client is ~1360 worst-case; some sites over-estimate PMTU
and drop large packets silently.

Fix: pin the client's wg0 MTU to 1280 when route-all is active.
The connector's heartbeat script already has the split-tunnel state
machine — add an `ip link set wg0 mtu 1280` on entry and `1420`
on exit.

### 4. Kill-switch semantics

When Jason's Mullvad tunnel drops mid-session:

- Host's default route is still the (dead) upstream tunnel
- Route-all clients' traffic goes `client → wg0 → jason → nowhere`
- From the client's perspective, internet is broken
- From a privacy perspective, this is fail-closed — traffic is not
  leaking through the home WAN

Accidentally this is the behavior security-conscious users want,
but it looks like "internet is broken" rather than "kill switch
engaged." We should:

- Detect upstream drop on the host (monitor `wg show wg0-up` last
  handshake age)
- Mark the exit as `Healthy: no` in the heartbeat report
- Show it as amber/red in the dashboard with a helpful label
  ("Upstream tunnel is down — all traffic is blocked until it
  reconnects")

Never silently fall through to the home WAN. That would be a
privacy regression.

### 5. IPv6

Provider WireGuard configs often include IPv6 AllowedIPs. wg0 is
currently v4-only. If the downstream client's OS happily uses v6
directly to dual-stack sites, the Mullvad exit is defeated for half
the traffic.

Phase 1 answer: disable IPv6 on the downstream client's wg0
interface when route-all is active. Heavy-handed but correct.

Phase later: support v6 tunneling end-to-end.

### 6. Provider-specific compatibility

Not every commercial VPN exposes stock WireGuard:

| Provider | Stock WG config? | Fits phase 1? |
|---|---|---|
| Mullvad | Yes | ✅ |
| Proton | Yes | ✅ |
| NordVPN | Partial (NordLynx — custom auth) | Probably not without provider work |
| ExpressVPN | No | ❌ |
| AzireVPN | Yes | ✅ |

**Launch as "Bring Your Own Mullvad Exit"** (or add Proton if
testing is cheap). Don't over-promise by listing generic "WireGuard
provider support."

### 7. Secret storage

The provider wg_config includes a private key. If we store it in
Postgres, it must be encrypted at rest. Options:

- Simplest: a symmetric key loaded from `DISCOVER_API_KEY`-style
  env var on the brain at startup, used with `chacha20poly1305` or
  AES-GCM. Adequate for v1.
- Proper: per-account wrapping with KMS/age/sops. Overkill for v1,
  right for later.

Either way, never log the decrypted value. Never return it in any
non-host-authenticated response.

---

## Naming

Candidates:

- **Bring Your Own Exit** ✅ — my preference; clearest, most honest
- Managed Upstream Exits — accurate but corporate-sounding
- Private LAN + Selectable Public Exit — descriptive but long

The dashboard label should be short: `Upstream Exit` or `Exit Node`.
The marketing/docs headline can be the full phrase.

---

## Business angle (marketing, not engineering)

- We are **not** competing with Mullvad. We make Mullvad more
  useful by letting customers compose it with a home-LAN tunnel
- Natural affiliate play: "sign up for Mullvad through wg0, we
  handle the host setup for you"
- Differentiator against Tailscale/Netbird: they do mesh well but
  don't meaningfully let you bring a commercial exit provider
- Differentiator against Mullvad: we also give you your home LAN
  simultaneously

The pitch in one sentence:

> *"Use your home network like home, but browse out of London, LA,
> or home WAN — your choice, on whichever device you choose."*

---

## What to avoid

- **Terminating provider tunnels in the wg0 cloud.** This turns
  wg0 into a transit network with bandwidth cost, abuse handling,
  compliance, and a 10× larger blast radius. Do not do this.
- **Promising "unlimited devices with one subscription."** Soften
  to "multiple downstream clients subject to provider terms, host
  bandwidth, and host reliability."
- **Shipping phase 3 (multi-exit-per-host) before phase 1.** The
  policy-routing complexity is a tarpit for a feature no customer
  has asked for yet.
- **Storing raw provider private keys unencrypted.** Obvious, but
  worth stating.
- **Silent fallthrough to home WAN when upstream dies.** Privacy
  regression. Fail closed and show a clear dashboard state.

---

## Phase checklist

| Phase | Scope | Code? | Status |
|---|---|---|---|
| 0 | Docs page: the hidden feature already works today | None | ✅ shipped |
| 1 | Managed BYO Exit, single exit per host | New table, 3 endpoints, PATCH extension, heartbeat enrichment, host connector state machine | ✅ shipped |
| 2 | Multiple stored exits, dashboard switcher | Already covered by Phase 1 (UI lets you add N, activate 1) | ✅ shipped as part of Phase 1 |
| 3 | Simultaneous multi-exit per host with per-client policy routing | Hard Linux routing work (`ip rule fwmark` per client overlay IP) | Not started |
| 4 | Direct client upstream (each device has its own provider profile) | Portal + mobile app surface | Probably never |

### What shipped in Phase 1

- **Schema:** `upstream_exits` table + `current_upstream_exit_id` FK on nodes
- **Brain endpoints:**
  - `POST /api/v1/nodes/:host_id/upstream-exits` — add a provider config
  - `GET /api/v1/nodes/:host_id/upstream-exits` — list (wg_config NOT included in list response; it has a private key)
  - `DELETE /api/v1/upstream-exits/:id` — remove
  - `PATCH /api/v1/nodes/:id` — extended with `current_upstream_exit_id` and `clear_upstream_exit` fields
- **Heartbeat:** host-node heartbeat response now carries an optional `upstream_exit` object with the full wg_config when an exit is active
- **Connector (Linux):** full state machine with `ip rule fwmark 0x100 lookup 51820` + secondary routing table for host-reachability — UDP 51820 replies route out the original physical interface regardless of default-route takeover
- **Connector (macOS):** state machine brings `wg-quick up`/`down wg0-up` in response to heartbeat. macOS has no clean `ip rule` equivalent, so the host's inbound reachability when the upstream is active relies on the discover sidecar observing the host's new Mullvad-mapped endpoint and the brain pushing it to peers on the next heartbeat. PersistentKeepalive = 25 on every peer keeps the Mullvad NAT hole open. Verified on our tested Sonoma/Sequoia setup — see "Host-reachability policy routing" for the full flow. No router port forwarding required.
- **Frontend:** `UpstreamExitsPanel` component shown on host-node expand row in native-LAN networks. Add/Activate/Deactivate/Delete. Active exits marked with green border + "Active" badge.
- **Trust model:** wg_config stored plaintext in Postgres. Encryption-at-rest is a fast-follow.

### Known limitations in Phase 1

1. **Per-client exit selection is not implemented.** All route-all clients on a host share the host's single active exit. If Scott wants LA and Sarah wants London simultaneously, Phase 3 is required. Phase 1 gives host-level selection only.

2. **macOS upstream reachability depends on discover.** There is no clean `ip rule` equivalent on macOS, so when the upstream tunnel owns the default route the host's own wg0 listener ends up speaking to peers through the upstream provider's NAT. In our tested setup (Mullvad + macOS Sonoma/Sequoia, consumer NAT underneath) the discover sidecar observes the host's new Mullvad-mapped endpoint, the brain distributes it to peers on the next heartbeat, and PersistentKeepalive=25 holds the mapping open. This is supported and verified, not a workaround — but it does depend on the upstream provider's NAT being friendly to UDP source-port preservation (Mullvad is; more hostile CGNAT chains may not be). We still ship the `ip rule` + `iptables mangle` path for Linux hosts where it's available, and a native `pf`-based backup on macOS is tracked as future work. Router port forwarding is **not** required.

3. **No health checks.** The dashboard shows `is_active: true` based on whether the brain has the exit assigned; it does not ping or verify the tunnel is actually passing traffic. A "last handshake" field from `wg show wg0-up` should be reported in a future heartbeat.

4. **No kill-switch dashboard UI.** When the upstream dies, route-all clients fail closed (traffic is black-holed at the host, never leaks to home WAN). This is the correct privacy behavior but the dashboard currently shows "everything fine" — it should show an amber "upstream down, clients offline" state.

5. **wg_config is stored plaintext.** OK for the current trust model but documented as a fast-follow.
