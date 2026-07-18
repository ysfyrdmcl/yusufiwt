# Data Usage

AgentControl does not track users and declares no collected data types. Local
session metadata, preferences and encrypted companion state are used only for
the app's user-facing functionality; they are not advertising or analytics
telemetry and are not sold.

The app and app-group extensions use `UserDefaults` only to read/write
AgentControl preferences and bounded glanceable snapshots. The privacy manifest
declares Apple's `CA92.1` app-only reason for
`NSPrivacyAccessedAPICategoryUserDefaults`. File metadata used by the macOS-only
managed configuration/recovery implementation is not used for fingerprinting or
sent off-device. See `Docs/PRIVACY.md` for field classification, retention,
relay ciphertext and diagnostic export rules.
