# BYO Exit — choose your own upstream VPN

**Tagline:** Attach your own Mullvad, Proton, Azire, or custom
WireGuard config to a host, route all your home traffic through it,
and see in the dashboard when the upstream is healthy or down.

**IMPORTANT WORDING NOTE FOR EVERY COPY DRAFT USING THIS PAGE:**
BYO Exit's **health visibility** is shipped (dashboard shows
healthy / stale / down / never / unknown states and updates every
~30 seconds via the host's heartbeat). BYO Exit's **traffic
enforcement** is **NOT** shipped — when the upstream is detected
as down, the dashboard warns, but the client does not yet drop
traffic. Do not use the phrase "fail-closed kill-switch" in any
copy derived from this page. Say "health-aware BYO Exit" or "BYO
Exit with upstream health monitoring." See
`MARKETING_CLAIMS.md` §2 for the precise wording templates and §3
for what's explicitly off-limits.

**Who this is for:**
- Privacy-conscious home users who already pay for Mullvad /
  Proton / Azire and want all their devices to use it without
  configuring the upstream on every device
- Developers who want their laptop to "look like" a specific city
  for testing geo-sensitive code
- Travelers who want traffic to come out of a known home country
  IP while abroad
- Small businesses that want all office egress to go through a
  commercial VPN for jurisdiction / GDPR reasons
- Anyone who's tried "put Mullvad on every device" and hit
  configuration drift, app installation pain, and "which one is
  the kill-switch?" confusion

**Primary pain point it solves:**

Commercial VPN providers ship great clients for phones and
laptops, but managing a fleet of devices through them is painful.
You install the Mullvad app on 6 devices and they each have
different settings, different kill-switch behaviors, different
DNS, and different UX when the tunnel hiccups. You pay Mullvad
once but the operational cost scales with your device count.

wg0's **Bring Your Own Exit** takes a different approach: you
upload your provider's WireGuard config to **one host machine**
at your home or office, activate it, and **every route-all client
on that host** automatically inherits the upstream. Add a new
device to the network, toggle route-all, done — the device
egresses through your Mullvad / Proton / etc. endpoint without
ever knowing about the upstream config.

The host effectively becomes a commercial-VPN exit node for all
your devices.

## What wg0 gives you

- **Upload a provider config** — Mullvad, Proton, Azire, or any
  custom WireGuard `wg0.conf`. The dashboard stores the config,
  tags it by provider type, and offers a one-click attach to any
  host.
- **Per-host activation** — pick a host, pick an uploaded exit,
  click activate. The host's next heartbeat brings up `wg0-up`
  via `wg-quick` and the upstream tunnel is live.
- **Client inheritance via route-all** — any client in the host's
  native-LAN network with `route_all_traffic=true` in its
  settings automatically egresses through whatever upstream is
  currently active on the host. Flip route-all on for a client,
  wait one heartbeat (~30s), and its internet traffic is going
  through your Mullvad endpoint.
- **Upstream health visibility** — host connectors probe
  `wg show wg0-up latest-handshakes` on every heartbeat and
  report the result to the brain. The dashboard shows an inline
  health badge on the host row with 6 possible states: `inactive`,
  `healthy`, `stale_report`, `never`, `down`, `unknown`. Full
  state table in `docs/ROADBLOCKS.md` §7.
- **Client-side warnings** — route-all clients whose host's
  upstream is unhealthy see an additional warning pill on their
  own row ("your upstream is down"), not just on the host's. So
  you don't have to know "which host is this client routing
  through?" to see that something's wrong.
- **Swap without re-enroll** — upload a second exit (e.g.
  Mullvad DE in addition to Mullvad SE), switch between them
  from the dashboard, and every client inherits the change on
  its next heartbeat. No device reconfiguration required.

## What it is today (precise language)

- **Health visibility is shipped.** The dashboard tells you when
  your upstream is working, stale, or broken, updated every ~30
  seconds.
- **Detection only, not enforcement.** When the dashboard shows
  "exit down," client traffic is NOT blocked. Packets may still
  attempt to flow through the host's physical WAN depending on
  the host's kernel routing state. A real fail-closed kill-switch
  (blackhole rules on the client when the upstream is dead) is
  tracked as the next iteration but is **not shipped**.
- **One active upstream per host.** If your host has both
  Mullvad SE and Proton LON uploaded, only one is active at a
  time. All route-all clients on that host share the active
  one.
- **Verified on macOS + Mullvad under consumer NAT.** Scott's
  test setup is a Sonoma macOS host with a Mullvad Sweden
  upstream behind a standard consumer router. Real-world
  verification on production Linux hardware is pending (see
  `MARKETING_CLAIMS.md` §2).

## What it is NOT today (explicit)

- **No fail-closed kill-switch.** When the upstream fails, the
  dashboard warns but the client keeps trying to send traffic.
  Customers who need "traffic MUST be blocked if the VPN dies"
  (the traditional "kill-switch" meaning) should wait for the
  enforcement Phase 2, or use a dedicated kill-switch tool on
  top of wg0.
- **No per-client exit selection.** If you want Scott's laptop
  to egress via Mullvad LON while Sarah's laptop egresses via
  Mullvad LA from the same host, that's a future feature. Today
  the host has one active exit and all route-all clients share
  it. ("Per-client exit selection" is explicitly deferred as a
  separate project — see `MARKETING_CLAIMS.md` §3.)
- **No DNS push from the upstream.** Your route-all clients keep
  their local DNS resolvers. If you want DNS to also flow
  through the VPN, that's a future feature. DNS leaks are
  possible depending on your local resolver configuration.
- **No automatic failover between uploaded exits.** If Mullvad SE
  goes down, the host does not automatically try Mullvad DE. You
  get a dashboard warning and switch manually.
- **Windows hosts are not supported for BYO Exit.** macOS and
  Linux only. Windows connector is client-only; BYO Exit on
  Windows is on the roadmap.
- **No per-upstream health history.** Today we store the latest
  snapshot only. A time series is tracked for later.

## Recommended setup pattern

**Scenario: Scott wants his home office to egress through Mullvad
SE, his MacBook to route all traffic through home when he's at a
coffee shop.**

1. Home office already has a native-LAN network (from the
   [Remote Access use case](./remote-access.md)).
2. Host is a Mac mini at home, enrolled with `role=host`.
3. Download a Mullvad WireGuard config from Mullvad's account
   page (pick the Sweden server).
4. Dashboard → Networks → click the home-native network → expand
   the Mac mini row → **Upstream exits** section.
5. Click **Upload exit**, give it a friendly name ("Mullvad SE"),
   paste the `wg0.conf` contents, choose provider type Mullvad.
6. Click **Activate**. Within 30 seconds, the host's next
   heartbeat brings up `wg0-up` via `wg-quick` and the badge on
   the host's row flips to **exit ok** (green).
7. On Scott's MacBook (already enrolled as a client in the same
   home-native network), open the node settings, flip
   **Route all traffic through host** to on.
8. Wait one heartbeat (~30s). Scott's MacBook now egresses through
   the Mac mini, which egresses through Mullvad SE. `curl
   https://api.ipify.org` from the MacBook returns a Mullvad SE
   IP, not the coffee shop's WAN IP.
9. When the coffee shop goes home at the end of the day, disable
   the MacBook's route-all toggle in the dashboard. Next
   heartbeat, the MacBook stops egressing through home and goes
   back to direct internet. The Mac mini's upstream stays active
   — other clients can still use it.

## Honest answers to the hard questions

**"Is this a kill-switch?"**
Not yet. It's health visibility. The dashboard tells you when
your upstream is down within ~30 seconds, but the client keeps
trying to send traffic through the dead tunnel during that
window. A true fail-closed kill-switch (blackhole rules on the
client) is the next iteration but not shipped. If you need
absolute "traffic MUST NOT leak" guarantees, you probably want
to use your provider's native app for now and revisit wg0 after
Phase 2 of the kill-switch work.

**"What if my host goes down?"**
The route-all clients that were egressing through it lose their
tunnel. Their traffic falls back to the physical WAN (not
blocked) after a timeout. Dashboard shows the host as Offline
and any route-all clients on that host as warning. New heartbeat
after host recovery restores the tunnel.

**"What if Mullvad goes down?"**
Host's `wg0-up` interface reports no fresh handshake, brain
derives `exit down` state within ~30 seconds, dashboard shows
red "exit down" badge on the host and on all route-all clients.
Traffic keeps trying to flow through the host — it's not
blocked. You switch to a backup exit manually from the
dashboard.

**"What providers are supported?"**
Any provider that hands you a plain WireGuard `wg0.conf`.
Tested explicitly on Mullvad. Proton, Azire, and custom
self-hosted WireGuard endpoints should work because the code
just does `wg-quick up`, but they haven't been exercised on
the health-reporting path yet.

**"Can I use OpenVPN / IKEv2?"**
No. BYO Exit is WireGuard-only because the host runs `wg-quick`
on your uploaded config. If your provider gives you OpenVPN
files, this isn't the product.

**"Can I run BYO Exit on a VPS instead of at home?"**
Yes. The host just needs to be Linux or macOS, reachable from
your clients, and able to run `wg-quick up wg0-up`. A cheap
Hetzner VPS works. The result is "all your route-all clients
egress through the VPS, which egresses through Mullvad." Good
for cases where your home internet is too variable.

**"Does it work on my phone?"**
Your phone can be a client of a native-LAN network via QR
provisioning, but stock WireGuard mobile apps don't have a
route-all toggle in wg0's sense. If you want your phone to
route through your home Mullvad, configure Mullvad directly in
the stock WireGuard app on your phone for now. A native wg0
mobile app with real-time settings would fix this; it's on the
roadmap.

## Sales talking points

**Opening line:** "Upload your Mullvad (or Proton, or Azire, or
custom) WireGuard config to one host at your home office, and
every device on your home LAN inherits the upstream. Stop
installing Mullvad on every device."

**Follow-up if they mention "kill-switch":** "We have upstream
health visibility shipped — the dashboard tells you when your
Mullvad tunnel is healthy or down within 30 seconds. We do
NOT currently enforce at the traffic level — if the tunnel
dies, we warn you, but we don't drop your traffic yet. If you
need absolute fail-closed behavior right now, use your
provider's native app for now and revisit when we ship
enforcement. If you can live with 'the dashboard tells me,'
wg0 works today."

**Follow-up if they mention per-client selection:** "Today you
pick one exit per host, and all route-all clients on that host
share it. Per-client selection (Scott via London, Sarah via LA
from the same host) is a bigger separate project — we're
explicit about it on our roadmap."

**Follow-up if they mention DNS:** "DNS push from the upstream
isn't shipped yet. Your local resolver keeps working as-is.
If you need the upstream's DNS to flow through the tunnel for
leak protection, that's a known roadmap item."

**Closing line:** "Start with Self-host Free if you want to try
it on your own hardware. Hosted Team at $49/mo gets you the
hosted brain plus BYO Exit plus everything else. Both include
the health visibility we just shipped."

## What to say after Mullvad verification tomorrow

When Scott finishes real-world Mullvad verification on production
hardware, we can add these claims to the copy above:

- "Verified end-to-end on Mullvad SE with a Sonoma macOS host
  under consumer NAT" (currently: verified pre-kill-switch; the
  health-reporting round is still synthetic)
- "Route-all clients continuously egress through Mullvad with no
  flap during normal operation" (currently: verified before the
  latest changes, pending re-verification)
- Specific numbers for heartbeat latency, flip-to-red time on
  tunnel teardown, flip-back-to-green time on tunnel recovery
  (currently: no real-world measurements yet)

Until then, keep the copy at "BYO Exit health visibility is
shipped; real-world end-to-end verification is in progress."
