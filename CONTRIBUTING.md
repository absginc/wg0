# Contributing to wg0

Thanks for wanting to improve wg0. This repo contains the public,
customer-installable pieces of the product — connector scripts, the
MCP server, and customer-facing API docs. The wg0 brain itself is
proprietary and lives in a private repository; this repo is
synchronized on every production push.

## What we accept

**Yes**, we love:

- Bug fixes in `connector/connector.sh`, `connector/connector-macos.sh`,
  and `connector/connector-windows.ps1`
- Portability improvements (distro-specific fixes, shell strictness,
  idempotency issues)
- New OS / platform support for the connector family
- Fixes or clarifications in `docs/`, especially `DEVICE_PROTOCOL.md`
  and `BYO_EXIT.md`
- MCP server improvements in `mcp/src/` — new tools, better error
  messages, additional prompt templates
- Typo fixes and clearer wording in `docs/usecases/`
- Additional language examples for the OpenAPI spec

**No**, please don't send:

- PRs that add features to the wg0 brain — the brain is not in this
  repo, so nothing here can affect it
- PRs that rewrite the install flow to work against a self-hosted
  brain — wg0 is a hosted product; use enterprise on-premise
  ([sales@wg0.io](mailto:sales@wg0.io)) if you need to run it yourself
- Breaking changes to the wire format without discussion first —
  device protocol changes need to coordinate with the brain side

## Reporting bugs

For anything that affects your account or your live networks, email
[support@wg0.io](mailto:support@wg0.io) — we reply faster there than
we do on GitHub issues.

Use GitHub issues for:

- Connector script bugs you can reproduce on a clean machine
- OpenAPI spec inaccuracies
- Documentation errors
- MCP server bugs

Please include the connector version (`wg0 --version` on Linux/macOS),
the OS and distro, and the exact command you ran. Redact any Personal
Access Tokens before pasting logs.

## Pull request guidelines

1. Open an issue first for anything bigger than a one-line fix — it
   saves everyone time if we agree on the approach up front.
2. Keep commits focused. One fix per PR; rebase instead of merging
   in from main.
3. Test on a real machine if you're touching a connector script —
   please don't rely on shellcheck alone for bash / sh changes.
4. Match the existing style. The connector scripts are deliberately
   conservative: POSIX-ish shell, defensive against missing tools,
   clear error messages.
5. Sign commits if you can. We don't require it yet, but we may
   later.

## Code of conduct

Be kind. We're a small team building something ambitious; constructive
criticism is welcome, personal attacks are not. Off-topic or
promotional posts will be closed.

## License

By submitting a contribution to this repository, you agree that your
contribution will be licensed under the [Apache License 2.0](LICENSE).
