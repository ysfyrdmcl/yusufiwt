# ADR 0014 — Stable question answers and configurable global hotkey

## Status

Accepted for Phase 0–8 remediation.

## Decision

- Question choices cross domain and local IPC as `{id, label}` values. Decisions
  return choice IDs, never presentation labels.
- Question kinds are single choice, multi choice, free text, confirmation, and
  secret. Free-text limits are explicit request capabilities. Secret answers
  are rejected by helper/notification paths and use terminal fallback only.
- Plan review has its own Approve, Request Changes (with bounded text), and Deny
  decisions. It does not reuse command-approval or question-answer payloads.
- The default global hotkey is Control-Option-Space. User customization is stored
  as a versioned setting. Legacy absence resolves to the plan default; an
  explicitly stored shortcut remains user-owned.

## Consequences

Wire decoding remains backward compatible with legacy string choices, mapping
them to deterministic IDs only at the compatibility boundary. New encoders emit
the structured contract. Notification actions may submit only non-secret,
currently pending decisions with the same revision and an unexpired request.
