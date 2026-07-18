# ADR 0018 — iOS companion authority boundary

## Status

Accepted for Phase 13.

## Decision

The iPhone is a paired decision endpoint, never an agent execution authority. It stores its X25519/Ed25519 private material and rotating relay credentials in a device-only Keychain access group shared only with the Notification Service Extension. Decrypted inbox/session state is protected in the app-group container and is never written by the extension.

Low and Medium approvals may originate from authentication-required notification actions. High approval exists only in the application after both a deliberate hold and successful biometric authentication. Critical approval and secret answers are forbidden on companion devices. Deny remains available wherever the unexpired request is current.

The extension may fetch and decrypt an opaque envelope to render a privacy-filtered notification, but it does not acknowledge or durably consume that envelope. The application acknowledges only after durable ingestion. A relay acceptance changes a decision to `awaitingProviderAcknowledgment`; only a signed Mac/provider acknowledgment may produce `applied` or `deniedApplied`.

## Consequences

- Dismissing a notification cannot lose the inbox item.
- A Face ID cancel/failure produces no signed decision.
- Offline decisions remain in a durable outbox and reconcile by request ID/version.
- Extension decryption/fetch failure renders a generic notification with no sensitive preview or approval action.
- Physical-device tests remain required because simulator builds cannot prove APNs, Keychain access-group, Secure Enclave or Face ID behavior.
