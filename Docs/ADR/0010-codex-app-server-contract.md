# ADR 0010: Codex managed app-server contract

- Status: Accepted
- Date: 2026-07-17

## Decision

The managed Codex adapter consumes the installed binary's stable, generated v2
app-server schema. Production traffic uses Codex's JSON-RPC-style JSONL dialect
(which omits the optional `jsonrpc` member) over stdio by
default; Unix-domain endpoints may be selected for compatible binaries.
Experimental WebSocket transport is not represented by the production adapter
API.

Compatibility is capability based. The generated schema must contain the
required handshake, managed-session, lifecycle, approval, and resolved-request
methods. A missing method puts the integration into explained monitor-only
mode. Approval correlation uses the JSON-RPC request ID, with Codex
`approvalId` retained as provider metadata where supplied.

AgentControl records a user decision as sent after writing the JSON-RPC
response, but records it as applied only after Codex emits
`serverRequest/resolved`. Process loss closes unresolved approvals as delivery
failures and triggers only bounded reconnect attempts.

## Consequences

- Version labels alone cannot silently enable an incompatible schema.
- Unknown notifications remain observable without changing session state.
- Diagnostic capture is metadata-only and excludes prompts, commands, diffs,
  paths, and process output.
