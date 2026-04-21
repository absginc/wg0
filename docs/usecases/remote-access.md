# Remote access into your existing office or home LAN

**Tagline:** Reach everything behind your LAN from anywhere — without
putting agents on your printers, NAS, or cameras.

**Who this is for:**
- Small business owners who want to work from home and still reach
  their office file server, line-of-business app, or camera system
- Developers who need SSH access to their homelab from a coffee shop
- IT admins supporting a small team with a mix of managed laptops
  and legacy LAN devices
- Anyone who tried Tailscale, liked it, and hit the moment where
  "install the app on the printer" was not actually an option

**Primary pain point it solves:**

Most mesh VPN products require every device to run an agent. That
works for laptops and servers, and breaks the moment you want to
reach a line-of-business system that only speaks IP — a network
printer, a Synology, a Hikvision NVR, a Shelly smart relay, a KVM
over IP, a Sonos system, a medical imaging terminal, a welder with
a web UI.

wg0's **native-LAN mode** lets one managed host (a spare laptop, a
Raspberry Pi, a NUC, your always-on Mac mini) join your remote
WireGuard network as a regular LAN member on your existing
`192.168.x.x` subnet. Every other device on your LAN keeps working
exactly as it does today. Your remote laptop joins the same
WireGuard network and gets a `192.168.1.200` address on the same
subnet — meaning you can hit your printer's web UI, SMB shares,
camera feeds, and anything else, just as if you were sitting on
the LAN.

## What wg0 gives you

- **Native-LAN networks** — remote devices appear as real members
  of your existing LAN, not an overlay subnet. Your LAN devices
  don't need to know anything has changed.
- **A five-minute first-device onboarding** — the dashboard walks
  you through network creation, token generation, and gives you
  the exact copy-paste commands for Linux, macOS, and Windows.
- **Four-state presence** — dashboard shows at a glance who's up
  and how we know: managed agent reporting directly, observed via
  the discover sidecar, or silent.
- **Honest "last activity" column** — no more sticky "last seen 3
  days ago" rows for devices that are actually fine.
- **Multi-tenant isolation** — your networks are yours; other wg0
  accounts can't see them even if they share the hosted brain.
- **Self-hostable** — if you don't want wg0 to host your control
  plane, the entire stack runs on any Docker host. Your call.

## Safe to claim today

- Native-LAN mode with a host running on Linux or macOS is
  production-ready. (Windows is client-only for now — see
  `MARKETING_CLAIMS.md` §3.)
- Route-all VPN mode (send all a client's internet traffic
  through the host) works on Linux and macOS.
- Discover sidecar handles most consumer NAT and cellular CGNAT
  without router port forwarding.
- QR code provisioning works for phones that need basic access
  (iOS, Android stock WireGuard apps).

## What's NOT included in the remote-access pitch

These things come up in conversation — be ready:

- **"Does it work on my phone?"** Yes, via QR code into the stock
  WireGuard app. But the phone can't receive dashboard updates
  (route-all toggles, etc.) the way managed desktops can. A
  native wg0 mobile app is on the roadmap.
- **"Can I SSO with my Google Workspace?"** Not yet. Account auth
  is email+password+JWT today. SSO is on the roadmap.
- **"What if the home LAN router doesn't support hairpin NAT?"**
  Discover sidecar handles most of these cases. For true symmetric
  NAT pairs (rare), there is no relay fallback yet — it's on the
  roadmap.
- **"Does it show up on the printer like a local IP?"** Yes — the
  remote client gets an IP in the host's LAN subnet, and the host
  uses proxy ARP on Linux or NAT on macOS to make LAN devices
  (including the router) see the remote client as a local
  neighbor.

## Recommended setup pattern

**Scenario: home office + small business owner who wants access
to their office LAN and one printer.**

1. Pick the always-on machine at the office. A Mac mini, NUC,
   Raspberry Pi, or spare laptop works. This becomes the
   **native-LAN host**.
2. Sign up at `https://login.wg0.io` (or deploy the self-host
   Docker Compose stack).
3. Create a network with type "native LAN," enter your existing
   office subnet (`192.168.1.0/24`), pick a tunnel IP for the host
   (`192.168.1.2`), and a small client pool (`192.168.1.200-220`).
4. Click **+ Add Device**, choose **Managed device**, pick the
   host's OS, and copy the enrollment command.
5. Run the command on the office machine. It installs the wg0
   connector, joins the network as a host, and starts
   heartbeating.
6. Click **+ Add Device** again on each remote laptop (same
   "Managed device" flow). Each enrolls as a client in the
   network and gets an IP in the office subnet.
7. From the remote laptop, hit your printer's web UI at its real
   `192.168.1.X` address. It works.

## Why wg0 instead of Tailscale for this specific case

- **Native-LAN vs subnet routing.** Tailscale supports subnet
  routers, but the remote devices are on a Tailscale overlay
  subnet (`100.x.x.x`) and reach the LAN via NAT'd routing. With
  wg0's native-LAN mode, remote devices are first-class members
  of your actual LAN subnet. Less translation, cleaner semantics.
- **Flat pricing.** If you have 40 devices on your LAN, Tailscale
  per-user pricing gets awkward. wg0's tentative flat-per-org
  pricing doesn't care how many devices you bolt on.
- **Self-host is always free.** Tailscale's free tier is time-
  bounded and feature-limited. wg0 self-host is the same product
  as hosted, minus the convenience of not running it yourself.
- **BYO Exit in the same product.** If you want all your remote
  traffic to egress through a Mullvad endpoint in Frankfurt, wg0
  does it in the same dashboard as your LAN access (see the
  BYO Exit use case).

## Why NOT wg0 for this specific case

- **If you need SSO / SAML**, wg0 doesn't have it yet. Tailscale,
  NetBird, and Cato all do.
- **If your users are phones first**, the QR-only mobile story is
  weaker than Tailscale's native iOS/Android app.
- **If you're in a symmetric-NAT-to-symmetric-NAT situation**
  (rare — cellular CGNAT on both sides, or some enterprise
  networks), wg0 has no relay fallback. Tailscale's DERP relays
  will work where wg0 direct-peer doesn't.

## Sales talking points

**Opening line:** "wg0 lets you reach everything on your office LAN
from anywhere — including the printers and cameras and line-of-
business systems that can't run agents. One managed host on the
LAN, and your remote devices become LAN members."

**Follow-up if they mention Tailscale:** "Tailscale is great if
you want a mesh of user devices. wg0 is different: we focus on
reaching the things you can't put an agent on. If your biggest
pain is 'I can't print from home,' wg0 is probably what you
want."

**Follow-up if they mention security:** "Per-device secrets, no
plaintext keys on disk, full audit of enrollment and PAT activity,
multi-tenant isolation by default. We're honest in our docs about
what we don't have yet — SSO and fine-grained API scopes are on
the roadmap."

**Closing line:** "Self-host is free forever, hosted starts at
$0 for 5 devices. You can try it without committing."
