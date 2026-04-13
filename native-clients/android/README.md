# wg0 Android Client

This is the first Android native-client scaffold for wg0.

Intended use:

- build a debuggable APK
- sideload on a test device
- prove login, managed enrollment, tunnel control, and heartbeat before
  Play Store work

## Current scaffold

- Android Studio / Gradle project shell
- Compose-based UI
- login / dashboard shell
- placeholder `VpnService`
- placeholder brain API interface

## Current goal

Use this project to prove the managed Android client model, not just a
stock WireGuard QR import.

Commercial boundary:

- no pricing
- no billing
- no upgrade CTA
- no account-purchase flow

This app is a connector for people who already have wg0 access.

## Next work

1. wire real login
2. add secure storage for device secret and session
3. implement the `VpnService` tunnel backend
4. add heartbeat and config refresh
5. build and sideload an APK

## Notes

- This scaffold intentionally stays separate from the main app so work
  can proceed without colliding with active backend/frontend changes.
- Android tooling is fast-moving; this scaffold uses a current official
  AGP/Compose baseline and should be refreshed if Android Studio wants
  to upgrade it. See official Android docs referenced in the final
  review message.
