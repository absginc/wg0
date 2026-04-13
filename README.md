# wg0

Connectors, MCP server, and API docs for [wg0.io](https://wg0.io) —
a hosted WireGuard control plane for homes, offices, and field teams.

This repository contains the customer-installable pieces of wg0. The
brain (the control plane itself) is proprietary and runs on our
infrastructure at `connect.wg0.io`. Use these tools to install our
connector on your machines, automate your networks from scripts or
AI agents, and integrate with the hosted API.

## Quick links

| I want to | Go to |
|---|---|
| Sign up for a free account | [login.wg0.io/register](https://login.wg0.io/register) |
| Enroll a Linux machine | `curl -sSf https://wg0.io/connector.sh \| sudo bash -s -- enroll <TOKEN> https://connect.wg0.io` |
| Enroll a macOS machine | `curl -sSf https://wg0.io/connector-macos.sh \| sudo bash -s -- enroll <TOKEN> https://connect.wg0.io` |
| Enroll on Windows | See [`connector/connector-windows.ps1`](connector/connector-windows.ps1) |
| Run as a Docker container | `docker run -d --cap-add=NET_ADMIN --device=/dev/net/tun -e ENROLLMENT_TOKEN=... -e BRAIN_URL=https://connect.wg0.io ghcr.io/absginc/wg0-connector` |
| Build against the API | [developers guide on wg0.io](https://wg0.io/developers.html) |
| Run the MCP server | See [`mcp/README.md`](mcp/README.md) |
| Read the OpenAPI spec | [`docs/openapi.yaml`](docs/openapi.yaml) |
| Understand BYO Exit | [`docs/BYO_EXIT.md`](docs/BYO_EXIT.md) |
| Build a custom connector | [`docs/DEVICE_PROTOCOL.md`](docs/DEVICE_PROTOCOL.md) |

`<TOKEN>` is an enrollment token you mint from the **+ Add Device**
button in the dashboard. The connector script supports `enroll`,
`update`, `unenroll`, and `rotate-secret` subcommands — see each
script's header comment for the full usage.

## What's in this repo

- **`connector/`** — Shell / PowerShell install scripts for Linux,
  macOS, and Windows. Idempotent, self-updating, configurable via
  environment variables. Handles enrollment, systemd / launchd /
  scheduled-task management, per-device secret rotation, and the
  heartbeat loop. Includes a **Docker connector** (`connector/docker/`)
  for running wg0 as a container — Alpine-based, under 40 MB.
- **`mcp/`** — TypeScript Model Context Protocol server. Wraps 16
  wg0 operations as tools so Claude Desktop, Claude Code, Cursor,
  and other MCP stdio clients can inspect and operate your networks
  conversationally. Authenticates via a Personal Access Token
  minted from the wg0 dashboard.
- **`docs/openapi.yaml`** — Full OpenAPI 3.1 spec for the wg0 REST
  API. Feed it to `openapi-generator-cli`, `orval`, or your codegen
  of choice for a typed client in any language.
- **`docs/llms.txt`** — Agent-discovery entry point following the
  [llmstxt.org](https://llmstxt.org) convention. Curated index of
  the canonical docs.
- **`docs/MCP.md`** — Install guide for the MCP server, covering
  Claude Desktop, Claude Code, Cursor, and Docker usage.
- **`docs/DEVICE_PROTOCOL.md`** — v1 and v2 device protocol spec.
  Relevant if you're building a custom connector for a platform
  the supplied scripts don't cover yet.
- **`docs/BYO_EXIT.md`** — How the Bring Your Own Exit feature
  works: upload a provider WireGuard config to a host, activate
  it, and every route-all client on that host inherits the
  upstream.
- **`docs/API.md`** — Human-friendly REST API reference with
  copy-pasteable curl recipes. The same content is rendered as
  HTML at [wg0.io/developers.html](https://wg0.io/developers.html).
- **`docs/usecases/`** — Use-case walkthroughs for remote access,
  satellite offices, BYO Exit, MSPs, and AI agents.

## What's NOT in this repo

The wg0 brain, the customer dashboard, and the discover sidecar are
proprietary and run on our hosted infrastructure at `connect.wg0.io`.
Managed accounts include everything you need to use the product
without running any of that yourself.

For enterprise on-premise deployment — where you need to run the
full control plane inside your own environment for data-residency,
regulated-industry, or air-gapped reasons — contact
[sales@wg0.io](mailto:sales@wg0.io) to discuss an enterprise
agreement.

## Getting started

1. Create a free account at [login.wg0.io/register](https://login.wg0.io/register).
   No credit card; 3 networks and 10 devices on the house.
2. Create a network in the dashboard, then click **+ Add Device**
   and copy the one-line install command for your platform.
3. Run it on the machine you want to connect. The connector handles
   everything else.

For programmatic access, mint a Personal Access Token from the
**API keys** page and point your scripts, cron jobs, or AI agents
at `https://connect.wg0.io`.

## Support and feedback

- **Questions about the product** — [support@wg0.io](mailto:support@wg0.io)
- **Sales, enterprise, and on-premise inquiries** — [sales@wg0.io](mailto:sales@wg0.io)
- **Bugs or fixes to the connector / MCP server / docs in this repo** —
  open an issue or pull request here. See [CONTRIBUTING.md](CONTRIBUTING.md)
  for guidelines.

## License

Apache License 2.0 — see [LICENSE](LICENSE) for the full text. You're
free to use, modify, and redistribute these connectors and tools. The
hosted brain remains proprietary and is not covered by this license.

---

Built on [WireGuard®](https://www.wireguard.com/) · WireGuard is a
registered trademark of Jason A. Donenfeld.
