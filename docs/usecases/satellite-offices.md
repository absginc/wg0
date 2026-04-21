# Satellite offices, branch locations, and field sites

**Tagline:** Connect your main office to three branches, six food
trucks, and a warehouse — without an MPLS, without a SASE contract,
and without putting a full VPN appliance at every site.

**Who this is for:**
- Small businesses with 2-6 physical locations (main office +
  satellites)
- Food-service businesses with pop-up kiosks, trucks, seasonal
  locations
- Trade shops with a main office + job-site trailers
- Medical, dental, veterinary chains with a main office + several
  clinics
- Field teams with a rotating set of short-lived sites (film
  crews, touring operations, event production)
- Anyone whose current answer is "the other location has a
  dedicated VPN appliance we bought 6 years ago and nobody
  touches"

**Primary pain point it solves:**

The middle tier of business networking is underserved. You're too
small to buy Cato or Palo Alto Prisma. You're too big for "my
partner set up a Raspberry Pi." You have 40 employees across 4
locations and you need them to see each other's LANs, print to
each other's printers, share line-of-business servers, and still
get honest observability into who's online and what's down.

wg0's **native-LAN mode per site** plus **host-reported peer
presence** gives you a real federation of small LANs with a single
control plane, a dashboard you can actually read, and connectors
that run on whatever hardware you happen to have (Mac mini, Intel
NUC, old laptop, spare VPS).

## What wg0 gives you

- **One native-LAN network per site** — each location keeps its
  own subnet and the host machine at each site bridges it into
  wg0. Remote devices joining any site's network become real
  members of that site's LAN.
- **Cross-site access via overlay networks** — create overlay
  networks that span multiple host machines; devices on one
  site's LAN can reach services at another site.
- **Honest status per site** — the dashboard shows each host's
  presence (online, observed, offline) and any BYO Exit it has
  attached. When a site goes dark, you see it instead of having
  to call the manager.
- **Cross-attested peer reports** — hosts report the peers they
  see via their heartbeats, so a laptop traveling between sites
  stays "online" as long as any site host can confirm its
  handshakes.
- **QR provisioning for temporary devices** — the cashier at a
  pop-up kiosk doesn't need IT to come by; they scan a QR code
  from the dashboard and the tablet is on the LAN.

## Safe to claim today

- Multi-site native-LAN deployment is the core product. If your
  architecture is "three Linux or macOS hosts at three sites,"
  wg0 runs this today.
- Hosts at each site are independent — taking one down doesn't
  affect the others. There's no single choke point (outside the
  control plane itself).
- Adding a new site is a single-form operation in the dashboard:
  create a native-LAN network, run the enrollment command on
  the site's host, you're live.
- Cross-attested presence means a device traveling between sites
  stays visible in the dashboard the whole time.

## What wg0 is NOT yet

- **Not a SASE platform.** There's no built-in SWG, DLP, CASB,
  identity posture, or security policy enforcement. If your
  compliance requirements include "all traffic must be inspected
  by a cloud proxy," you need a real SASE product.
- **Not a managed SD-WAN appliance.** There's no purpose-built
  hardware, no shipping-box-to-site onboarding, no four-nines
  SLA. You run wg0 on whatever hardware you already have, or on
  a cheap spare machine.
- **No DNS failover or automatic site-to-site routing between
  overlays.** Routing between overlay networks is manual today.
- **No BGP or routing protocols at the site level.** Each host
  owns its site's subnet; cross-site traffic goes via the
  WireGuard mesh.

## Recommended setup patterns

### Pattern 1: Main office + branches with separate LANs

- **Main office:** native-LAN network on the office's real subnet
  (`192.168.1.0/24`), host running on the existing Mac mini / NUC.
- **Branch 1:** different native-LAN network on its own subnet
  (`192.168.2.0/24`), host running on a Raspberry Pi.
- **Branch 2:** same pattern, subnet `192.168.3.0/24`.
- **Staff laptops:** enrolled in whichever site they primarily
  work at, with manual route configuration for cross-site access
  if needed.

Pros: each site keeps its own LAN clean. No address collision
risk. Clear ownership.

Cons: staff who move between sites need to re-enroll or have
explicit cross-site routes set up.

### Pattern 2: Unified overlay + native-LAN bridges

- **Overlay network** (`10.64.0.0/24`) spanning all employees at
  all sites. Each employee laptop has an overlay IP.
- **Per-site native-LAN networks** for the LAN devices at each
  site.
- **Hosts at each site** participate in both the overlay network
  and their own native-LAN network, acting as bridges.

Pros: single employee identity across all sites. Overlay IPs
don't change when you move.

Cons: more routing complexity. Overlay addresses don't map
directly to LAN addresses at any site — you can reach printers by
friendly name or via a site-local IP, not by a "unified" IP.

### Pattern 3: "Traveling trailer" / pop-up site

- **Main office** has a permanent native-LAN network as above.
- **Temporary site** (pop-up kiosk, food truck, touring rig) runs
  a wg0 host on a travel router or a cheap laptop. Its native-LAN
  network is ephemeral — created for the event, deleted when
  done.
- **All devices** at the temporary site enroll in the temporary
  network and reach each other + the main office.

Pros: doesn't require a permanent investment at the temporary
site. QR provisioning gets everyone on in 30 seconds.

Cons: cellular CGNAT at the temporary site can cause
connectivity issues — discover sidecar handles most of them,
but not symmetric-NAT scenarios.

## Common questions for satellite-office buyers

**"Do I need a VPN appliance at each site?"**
No. A managed Linux or macOS machine works. If you don't already
have one, a $150 Intel NUC or a $35 Raspberry Pi 4 is enough for
a small site.

**"What happens if the main office goes down?"**
The other sites keep working independently. wg0 has no
main-office dependency in the data path — peers talk directly to
each other via WireGuard once they've discovered each other via
the brain. The brain's role is coordination, not traffic relay.
If the brain (hosted control plane) is temporarily down, existing
tunnels keep working; new enrollments can't happen until it's
back.

**"Do I get audit logs?"**
Dashboard shows enrollment events, PAT activity, and presence
history. Full structured audit log export is roadmap.

**"What about compliance?"**
wg0 is a networking product, not a compliance product. If you
need HIPAA, PCI-DSS, or SOC 2 posture enforcement, you need a
product that does those things. wg0 can be part of a compliant
deployment, but by itself it doesn't assert compliance.

**"How do I update everything?"**
The `update` subcommand on each connector pulls the latest
heartbeat template from `https://wg0.io/connector-*.sh`. The
dashboard tracks which sites are running which version via
`last_activity` and per-node presence badges, so you can see
at a glance who's up to date.

## Sales talking points

**Opening line:** "You can run wg0 across 3 sites for the price
of one SASE seat at Cato. Each site runs a small host on any
Linux or Mac, and the dashboard shows you everything in one
view — who's up, who's down, what's routing through what."

**Follow-up if they mention cost:** "Self-host is free. Hosted
Team is $49/mo flat for up to 5 networks and 150 devices per
network. That's probably already cheaper than the line item
you're paying for your current VPN appliance's support
contract."

**Follow-up if they mention complexity:** "One dashboard, one
control plane. Adding a new site is: create a network, run one
command on the site's host, done. Adding a new staff laptop is:
click the button, run one command. No MPLS, no WAN acceleration,
no four-page runbook."

**Follow-up if they mention reliability:** "The data plane is
WireGuard — it doesn't depend on the control plane staying up.
If our hosted brain has a 5-minute hiccup, your existing tunnels
keep working. New enrollments pause until we're back, same as
every other SaaS control plane."

**Closing line:** "Try a two-site setup for free with self-host,
or sign up for Hosted Starter and see if it works for one
site + one WFH laptop. If it does, the math for adding more
sites is obvious."
