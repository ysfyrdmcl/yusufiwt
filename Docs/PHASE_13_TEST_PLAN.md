# Phase 13 test plan

## Automated gates

- `swift test --disable-sandbox --filter AgentCompanionTests`
  - notification/app decision surfaces enforce Low/Medium, High and Critical policy.
  - secret and expired questions fail closed.
  - durable outbox cannot report success before provider acknowledgment.
  - notification privacy, generic fallback, QR codec and deep links are deterministic.
- `Tests/Contracts/test_phase13_contract.sh`
  - iOS screens, Sign in with Apple, scanner, Face ID, hold gesture and revoke UI exist.
  - app/extension share only the declared App Group and Keychain access group.
  - High/Critical notification categories do not contain an approve action.
  - English and Turkish strings are complete.
- `xcodebuild -project AgentControl.xcodeproj -scheme AgentControliOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`
  - builds the iOS app and embedded Notification Service Extension with strict concurrency and warnings as errors.

## Physical-device and staging gates

1. Complete Sign in with Apple on a physical iPhone, including cancel/failure and refresh-token rotation.
2. Scan a real Mac QR, compare the fingerprint on both devices, reject a mismatch, then confirm a match.
3. Send Low and Medium notifications while the phone is locked; verify authentication-required Approve/Deny and final Mac/provider acknowledgment.
4. Confirm High offers Review/Deny only, requires app launch, a 1.5-second hold and Face ID. Cancel/fail Face ID and verify no decision envelope is created.
5. Confirm Critical and secret questions never expose companion approval/text entry; Deny/Open Mac remain available.
6. Disable networking, queue a decision, cross its expiry, reconnect and verify `expired` rather than applied. Repeat with a superseding request revision.
7. Deliver a corrupted, unavailable and expired envelope to the extension; each must render the generic notification without plaintext or actions.
8. Tap notification and `agentcontrol://inbox/<id>` / `agentcontrol://session/<id>` deep links and verify the exact detail opens.
9. Revoke the iPhone, verify refresh/pending fetch fails immediately, and confirm device-only keys do not restore on another device.
10. Exercise Hidden, Project Only and Full notification privacy settings on the lock screen.

Phase 13 is not `Verified` until automated gates, physical-device/staging gates and a commit SHA are recorded.
