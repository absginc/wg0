# wg0 macOS Client

This is the first native desktop client scaffold for wg0.

Why macOS first:

- strongest current connector maturity
- clear product value for a WARP-style desktop app
- DMG distribution is enough to prove the workflow before store work

## Intended MVP

- SwiftUI app
- email/password login
- app-managed device enrollment
- background heartbeat
- visible connect/disconnect state
- local storage for device secret and configuration
- no billing, pricing, or upgrade flow

## Current scaffold

- Swift Package executable app shell
- login view
- connected/disconnected dashboard shell
- protocol-oriented service abstractions for:
  - brain session
  - tunnel control
  - heartbeat

## Open in Xcode

Open this folder or `Package.swift` in Xcode on macOS.

## Expected next work

1. replace mock brain session with real HTTP client
2. wire secure storage
3. choose tunnel backend for MVP
4. add heartbeat lifecycle
5. add packaging/signing notes for DMG distribution
