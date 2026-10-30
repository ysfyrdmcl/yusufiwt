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

## Local IPC version 1.2

Minor 1.2 adds `interruptCodexSession(SessionID)` and
`codexInterruptRequested(Bool)`. The helper verifies the stored provider and
external thread identity, then requests interruption through the desktop's
stdio relay. Its private same-user IPC endpoint uses the native thread UUID
in the identifier field and accepts only negotiation and interruption.
A positive result means the stop request was acknowledged; only a
subsequent provider lifecycle event confirms completion. Older helpers do not
receive this request.

App-to-helper requests use authenticated XPC and negotiate the highest mutually
supported major/minor pair. A 1.1 client sends its supported `LocalIPCVersion`
list first; a pre-1.1 helper is retried through the legacy major-only handshake.
The helper continues accepting that legacy request. `XPCMessage` is
`NSSecureCoding`, contains at most 1 MiB, and wraps a Codable
`HelperRequest`/`HelperResponse`. Registry events are delivered through a
callback endpoint bridged to `AsyncStream`; the client reconnects with capped
exponential backoff.

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
monotonic revision. Lifecycle read models distinguish `awaitingUser`,
`userResolvedAwaitingProviderAck`, `automaticallyResolvedAwaitingProviderAck`,
`providerAcknowledged`, `applied`, `deniedApplied`, `expired`, `cancelled`,
`superseded`, and `providerRejected`. Expired requests, revision mismatches,
invalid question answers, and missing requests never become approvals. Helper
shutdown cancels all waiters with a neutral result.

Status events use a short timeout and are atomically spooled with owner-only
permissions when the helper is unavailable. Synchronous decision requests are
never spooled: once the provider hook has fallen back, replaying the request as
telemetry could create stale `waitingApproval` state but could no longer answer
the provider. Helper absence and timeout therefore remain strictly neutral.

## Structured usage contract

`session.usageUpdated` carries typed `SessionUsageMetric` values. Quota
remaining, context-window remaining, and input/output/total token counters are
different metric kinds and are never relabeled as each other. Percentages are
clamped to 0...100, stale metrics remain marked stale, and absent data is
represented as unavailable rather than `0%`. Session snapshots persist the
newest metrics through immutable SQLite migration 3; older snapshots decode
with an empty metric list.
