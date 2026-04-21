# wg0 for MSPs (managed service providers)

**Tagline:** Self-host a WireGuard control plane, onboard your
clients as tenants, give each one their own private networking
without running 30 separate Tailscale accounts.

**Important:** read `MARKETING_CLAIMS.md` before quoting anything
here in customer conversations. Several MSP-specific features
(delegated admin, per-customer billing, branded dashboards) are on
the roadmap, not shipped. This page is honest about that — do not
extract sales copy from it that claims otherwise.

**Who this is for:**
- Two-to-five-person IT shops supporting 5-30 small business
  clients
- Solo IT consultants with a portfolio of clients
- Managed service providers who've been using Tailscale per-client
  and hit the billing / isolation / account-management pain
- IT teams inside a larger org that act as "internal MSP" for
  multiple business units

**Primary pain point it solves:**

MSPs using per-device mesh VPN products end up juggling one
vendor account per customer, which means:

- Multiple separate billing relationships
- Multiple separate logins to remember
- No unified "all my customers" view
- Customer credentials mixed with your own
- Every customer has to "own" the account even though you're
  operating it

wg0's multi-tenant architecture puts every customer's networks
in their own isolated account under a brain you control (self-
hosted or the hosted instance). Each customer's networks, nodes,
tokens, and PATs are namespace-isolated. You, as the operator,
can script the whole thing via the API.

## What wg0 gives you today

- **Self-host the brain** — run your own `connect.yourMSP.com`
  backed by your own Postgres. Customers don't have to trust
  a third-party SaaS — they trust you.
- **Per-customer account isolation** — each customer you onboard
  gets their own account with their own networks, nodes, and
  credentials. No cross-tenant visibility at the database level.
- **Script everything via the API** — OpenAPI 3.1 spec, REST,
  JWT or PAT auth. You can write an onboarding script that
  registers a customer account, creates networks, mints an
  enrollment token, and emails them the install instructions,
  all without touching the dashboard.
- **MCP server for automation agents** — point a Claude Code
  session at your wg0 brain via PAT, say "list all my
  customers' networks and show me which ones are degraded,"
  get a coherent answer.
- **Shared underlying infrastructure** — one brain, one discover
  sidecar, one Postgres, serving all your customers. Your
  hosting costs don't scale linearly with customer count.
- **Self-hosted means you set the pricing** — bill your
  customers whatever you want; wg0 doesn't care. Your margin,
  your contracts, your support policy.

## What wg0 does NOT give MSPs today

Be very explicit about these when pitching:

- **No delegated admin / "MSP multi-login".** Today you log into
  each customer's account separately to manage their networks
  via the dashboard. You can script around this with PATs and
  the API, but the dashboard doesn't have an "MSP operator"
  role that can jump between customer accounts. **Roadmap.**
- **No per-customer billing pass-through.** wg0 doesn't issue
  per-customer invoices or handle Stripe connections for you.
  You bill your customers yourself. **Roadmap.**
- **No branded / white-label dashboards.** Every customer sees
  "wg0" in the dashboard UI. You can't put your MSP's logo on
  their view yet. **Roadmap.**
- **No hierarchical account structure.** Customers can't have
  sub-accounts or departments with separate permissions. One
  account, one set of credentials, period. **Roadmap.**
- **No built-in audit log export.** Dashboard shows enrollment
  events and presence history, but there's no "export last 90
  days of events as CSV for customer X's compliance review"
  feature. You can query the brain's Postgres directly if
  you're self-hosting. **Roadmap.**

**Net-net:** the multi-tenant plumbing that MSPs need is there,
but the MSP-specific operator UX is not. Treat wg0 today as
"self-hostable control plane with good API access that happens
to work for MSP use cases" rather than "purpose-built MSP
platform."

## Recommended setup pattern

### Phase 1: self-host + manual onboarding (today)

1. **Deploy a self-hosted wg0 brain** on your ops VPS. Docker
   Compose stack: brain, frontend, admin, start (connector
   scripts), discover sidecar, Postgres. All under one
   `docker-compose up -d`.
2. **Point it at your own domain** — `wg0.yourMSP.com` for the
   customer dashboard, `connect.yourMSP.com` for the connector
   API, `admin.yourMSP.com` for the admin surface (firewall
   this to your office IP).
3. **Register each customer as an account** via the
   `/api/v1/auth/register` endpoint. Do this from a script so
   you can standardize names, set initial passwords, and send
   the customer a welcome email with their own credentials.
4. **Create the customer's initial networks** via the API
   (overlay or native-LAN depending on what they need), mint an
   enrollment token, and either:
   - Ship them a pre-filled install script (Linux/macOS/
     Windows), or
   - Send them the dashboard URL so they can click **+ Add
     Device** themselves
5. **Give the customer the dashboard URL and their password.**
   They can manage their own devices from there.
6. **You keep a set of PATs** (one per customer, minted from the
   customer account) in your automation scripts. Those PATs let
   your monitoring + diagnostic tooling query the customer's
   state without needing the customer's password.

### Phase 2: partial automation via API (today)

Write tooling that uses the MCP server or direct REST calls to:

- Poll all your customers' networks for presence and flag
  anything that's been offline for >24h
- Check BYO Exit health on any customer using it
- Mint short-lived PATs for ad-hoc customer support sessions
  (you log in as them via the JWT path to mint, then revoke
  after)
- Generate a "health report" for each customer's monthly
  invoice
- Trigger alerts when a customer's host goes down

All of this works today via the REST API + PAT auth. It's not
pretty, but it's fully functional.

### Phase 3: dedicated MSP tier (roadmap)

When the MSP-specific features ship, the Phase 1/2 workflow
gets replaced with:

- **A single MSP operator login** that lists all your customers
  and lets you jump into any of their dashboards
- **Per-customer billing** routed through wg0 with pass-through
  or markup options
- **White-label dashboards** with your branding per customer
- **Pre-built onboarding flows** ("click this, enter customer
  name, get a package of credentials and install scripts")
- **Audit log export per customer** for compliance work

**Timeline:** no commitment. We'll prioritize this based on how
many MSPs are actually using Phase 1/2 and what they tell us is
most painful. If you're reading this and MSP is your primary use
case, reach out — that's our signal to build the features you
need.

## Honest answers to MSP questions

**"Is it a real MSP platform?"**
No, not yet. It's a multi-tenant control plane that MSPs can use
with scripting and self-host operational discipline. The
MSP-specific UX is roadmap. Set expectations accordingly.

**"Can I support 50 clients on wg0 today?"**
Technically yes, operationally it's rough. Each customer means a
separate login and a separate dashboard. At 50 customers you'll
be writing substantial scripting around the API just to stay
sane. If you can tolerate that now in exchange for getting in
early on a product that's building the MSP features you want,
reach out.

**"What about SLA / uptime guarantees?"**
If you're self-hosting, the SLA is yours to set — you run it.
If you're using the hosted brain at `connect.wg0.io`, we target
99% today and aim for 99.5% as we mature. No financial SLA
commitments yet; we'll add those once we have measured uptime
history and a billing relationship that justifies them.

**"Can I brand it with my logo?"**
Not yet. Dashboard says "wg0" and shows wg0's icons. Branded
dashboards are on the MSP roadmap but not shipped.

**"Do I own the customer data?"**
If you self-host, yes — it's your Postgres, your backups, your
policies. If you use the hosted brain, wg0 owns the
infrastructure and you own the tenant data; we're honest that
"your customer's networks" are stored in our Postgres if you use
hosted. Self-host is always the answer for MSPs that need strict
data-residency guarantees.

**"What if wg0 goes out of business?"**
Self-host is the answer. The entire stack is open-source-ish
(read: source-visible and you can run your own fork). You own
your Postgres. You own the connectors your customers have
installed. Worst case, you maintain the fork. This is a real
buyer-confidence factor for MSPs and it's worth being explicit
about.

## Sales talking points

**Opening line:** "wg0 is self-hostable, multi-tenant, and
API-first — three properties that matter more to MSPs than they
do to single-tenant buyers. You run your own brain, your
customers are isolated accounts, you automate the onboarding
with scripts."

**Follow-up if they ask about MSP-specific features:** "Today
the MSP flow is self-hosted multi-tenancy + scripting. There's
no dedicated MSP operator role, no per-customer billing
integration, no branded dashboards. Those are on the roadmap,
not the product. If that's acceptable for the next 6-12 months
in exchange for getting a say in what ships, we should talk."

**Follow-up if they ask about pricing:** "Self-host is free
forever — so if you're running the brain yourself, wg0 costs
you nothing in licensing, just your own hosting. Hosted tier
for MSPs is 'Hosted Business today plus a roadmap promise' —
we'll build MSP-specific features based on what the first few
MSPs tell us they need most."

**Closing line:** "If you want to prototype an MSP offering on
wg0 today, we'll help you set up the self-hosted brain and
walk you through the scripting patterns. In return, we want
feedback on what to build next. No formal contract required
for that — just be willing to be a design partner."
