# Protocol Contract

Phase 1 defines protocol version 1 in
`Packages/AgentControlKit/Sources/AgentProtocol/JSONSchema`.

Every event carries a globally unique event ID, normalized source, strong
session ID, provider sequence, two RFC 3339 timestamps, privacy class,
correlation ID, and schema hash. Encoded envelopes are limited to 1 MiB.

Unknown top-level fields are ignored. Unknown event types are preserved as
`AgentEvent.unknown` and do not mutate session state. Duplicate event IDs and
non-increasing sequences for the same source key are idempotent no-ops.

Approval events cannot produce `applied` or `deniedApplied` before a correlated
provider acknowledgment advances the approval lifecycle.

## Local IPC version 1

App-to-helper requests use authenticated XPC and negotiate the highest mutually
supported protocol version. `XPCMessage` is `NSSecureCoding`, contains at most
1 MiB, and wraps a Codable `HelperRequest`/`HelperResponse`. Registry events are
delivered through a callback endpoint bridged to `AsyncStream`; the client
reconnects with capped exponential backoff.

Hook-to-helper traffic uses a Unix-domain socket frame with 4-byte `ACIP` magic,
big-endian UInt16 version and message type, big-endian UInt32 payload length,
32-byte SHA-256 payload checksum, and payload. Invalid magic, unknown version,
unknown type, oversized/truncated data, trailing bytes, and checksum mismatch
are rejected before decoding. Helper absence or timeout produces a neutral
fallback and never an allow decision.

## Hook decision contract

`agentcontrol-hook` supports `emit`, `notify`, `request-decision`, `doctor`, and
`version`. Event and decision input is bounded to 1 MiB and 64 JSON nesting
levels. Provider responses are the only content written to stdout; diagnostics
are written to stderr.

A decision request is first persisted as an event and then held by the helper's
in-memory decision broker. Inspector/UI clients resolve it by request ID and
monotonic revision. Expired requests, revision mismatches, invalid question
answers, and missing requests never become approvals. Helper shutdown cancels
all waiters with a neutral result.

Status events use a short timeout and are atomically spooled with owner-only
permissions when the helper is unavailable. Decision events are also spooled
for audit, but the synchronous result remains neutral so the provider can show
its native prompt. Spool delivery is never interpreted as approval.
