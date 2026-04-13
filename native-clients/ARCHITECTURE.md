# Native Client Architecture

This document defines the intended shape of the first wg0 native apps.

## Product intent

The native clients should feel closer to Cloudflare WARP or Tailscale
than to a shell script:

- login inside the app
- clear connection state
- one-click connect / disconnect
- background heartbeat
- useful status when disconnected, degraded, or restricted
- connector logic hidden behind a native UI

## Shared product rules

All native clients should converge on the same model:

1. Human auth
   - Today: email + password via wg0 JWT login.
   - Later: SSO/OIDC can slot into the same auth state machine.

2. Device enrollment
   - Managed devices should use the documented device protocol.
   - Device secrets are stored locally and never shown again after
     enrollment.

3. Desired-state loop
   - App reports current state.
   - Brain returns desired state.
   - Client converges tunnel peers, routes, and status locally.

4. Clear separation of concerns
   - UI layer
   - brain/session layer
   - enrollment/config layer
   - tunnel controller
   - heartbeat engine
   - secret storage

5. Honest device classes
   - macOS native app is a managed device.
   - Android native app should become a managed device.
   - Stock WireGuard QR import remains a provisioned peer and is not the
     same product surface.

6. Connector-only commercial boundary
   - Native apps do not sell wg0.
   - Native apps do not render pricing tiers.
   - Native apps do not run checkout, billing portal, upgrade CTA, or
     plan-management flows.
   - Native apps assume the user already has wg0 access through the web
     product, an org admin, or an invite flow.
   - If access is missing, the app should explain that clearly and send
     the user back to the web/admin path, not try to monetize in-app.

## Shared backend touchpoints

These are the main existing APIs the native apps should speak to:

- `POST /api/v1/auth/login`
- `GET /api/v1/accounts/me`
- `GET /api/v1/my-access`
- `POST /api/v1/my-access/:profile_id/enroll-token`
- `POST /api/v1/my-access/:profile_id/provision`
- `POST /api/v1/nodes/:id/heartbeat`
- `GET /api/v1/nodes/:id/config`
- `POST /api/v1/nodes/:id/rotate-secret`
- `DELETE /api/v1/nodes/:id/self`

Longer term, native clients should move toward the stricter v2 device
protocol described in [DEVICE_PROTOCOL.md](/root/abs-link/docs/DEVICE_PROTOCOL.md).

## Known backend caveats to keep in view

As of this scaffold:

- The member self-service managed enrollment token flow still needs the
  profile context to be enforced again at token redemption time.
- The member self-service QR/manual flow still needs full parity with
  the main provisioning path if it is going to power a real managed
  mobile experience.

Native clients should therefore prefer the managed-device path and help
pressure the backend toward the formal device protocol rather than
building permanent logic around the current shell-era shortcuts.

## macOS app shape

Recommended first version:

- SwiftUI app shell
- Login screen
- Account / device summary screen
- Connect / disconnect control
- Background heartbeat engine
- No billing or pricing surfaces
- Local secure storage for:
  - JWT / refresh-equivalent session material if introduced later
  - node id
  - device secret
  - WireGuard private key
- Tunnel controller abstraction that can start with a shell-backed
  implementation and later swap to a more native tunnel provider path

Suggested modules:

- `BrainSession`
- `ConnectorCoordinator`
- `HeartbeatService`
- `TunnelController`
- `SecretStore`
- `AppModel`

## Android app shape

Recommended first version:

- Jetpack Compose UI
- Login screen
- `VpnService` shell
- Background worker / foreground service for heartbeats and state
- No billing or pricing surfaces
- Encrypted local storage for device secret and session
- Clear separation between human auth state and device state

Suggested modules:

- `BrainApi`
- `SessionStore`
- `EnrollmentRepository`
- `TunnelRepository`
- `HeartbeatWorker`
- `Wg0VpnService`

## What "done enough to test" looks like

### macOS MVP

- sign in with email/password
- choose or create a managed device enrollment path
- enroll once
- store device secret locally
- connect/disconnect from native UI
- heartbeat every 30s while enrolled
- show current presence / last error / last handshake summary

### Android MVP

- sign in with email/password
- provision or enroll as a managed device
- establish a `VpnService` tunnel
- heartbeat while service is active
- show tunnel status and basic error state
- produce a debuggable APK for sideload testing
