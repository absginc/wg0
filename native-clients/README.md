# wg0 Native Clients

This workspace is the starting point for native connector apps that sit
next to the existing shell-based connectors.

Why this exists:

- `/connector/*.sh` and `connector-windows.ps1` prove the product.
- Native apps are the next product step for polished onboarding,
  background status, connection toggles, and app-store/distribution
  flows.
- We want to build these clients against the documented wg0 device
  protocol instead of re-embedding shell assumptions forever.

Current focus:

1. `macos/` — first native desktop client, SwiftUI shell, DMG-friendly
   distribution, login + connection state + heartbeat architecture.
2. `android/` — first mobile-managed client, APK-first workflow,
   `VpnService`-based tunnel shell, login + state + heartbeat
   architecture.

Important repo boundaries:

- Main product remains in `/root/abs-link`.
- Claude is actively working there.
- This workspace is intentionally disjoint so native-client work can
  move forward without colliding with backend/frontend changes.

Read these first:

- [ARCHITECTURE.md](/root/abs-link/native-clients/ARCHITECTURE.md)
- [HANDOFF_FOR_CLAUDE.md](/root/abs-link/native-clients/HANDOFF_FOR_CLAUDE.md)
- [DEVICE_PROTOCOL.md](/root/abs-link/docs/DEVICE_PROTOCOL.md)
- [ROADBLOCKS.md](/root/abs-link/docs/ROADBLOCKS.md)

Subprojects:

- [macos](/root/abs-link/native-clients/macos)
- [android](/root/abs-link/native-clients/android)
