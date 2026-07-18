# Phase 5 Test Plan

Phase 5 supplies the managed Codex `app-server` reference adapter. The runtime
uses Codex's generated request/response dialect over JSONL and defaults to stdio. Its public production
endpoint model intentionally has no WebSocket case.

## Automated coverage

- Codex binary/version detection and local generated-schema compatibility.
- Initialize/initialized handshake plus managed `thread/start`, `turn/start`,
  and `turn/interrupt` request construction.
- Recorded JSONL fixtures for thread, turn, item, approval, provider-resolved,
  completion, unknown-event, and malformed-line behavior.
- Command/file approval correlation with parallel numeric and string RPC IDs.
- Expiry, turn cancellation, process crash, and bounded reconnect behavior.
- Provider acknowledgment authority: `applied` and `deniedApplied` are emitted
  only after `serverRequest/resolved`.
- Monitor-only fallback when required schema methods are absent.
- Redacted bounded diagnostics that retain correlation IDs but never command,
  prompt, output, or path content.

## Local integration smoke test

Generate the installed Codex schema and run the adapter tests:

```sh
schema_dir=$(mktemp -d /private/tmp/agentcontrol-codex-schema.XXXXXX)
codex app-server generate-json-schema --out "$schema_dir"
swift test --filter AgentCodexAdapterTests
```

The installed binary must expose `initialize`, `thread/start`, `turn/start`,
the two v2 approval requests, item/turn lifecycle notifications, and
`serverRequest/resolved`. Missing required methods select monitor-only mode;
the adapter does not guess a changed approval schema.

## Manual real-session acceptance

Run AgentControl with an authenticated Codex installation, start a managed
thread in a disposable repository, then request one command and one file
change. Confirm live state updates, approve one request, deny the other, and
cancel an active turn. Neither request may appear applied before Codex emits
`serverRequest/resolved`. Kill the child app-server once and confirm a bounded
reconnect followed by a fresh initialize handshake.
