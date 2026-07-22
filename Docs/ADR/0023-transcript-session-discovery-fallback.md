# ADR 0023: Transcript session discovery fallback

- Status: Accepted
- Date: 2026-07-21

## Decision

The macOS helper polls the structured JSONL transcripts already written by
Codex and Claude Code every two seconds as a monitor-only discovery fallback.
It reads only bounded session metadata needed for identity, project location,
parent/subagent grouping and file modification time. Prompt, assistant and tool
content is not emitted or persisted.

A transcript updated within 20 seconds is treated as running; after that it is
treated as completed, and transcripts older than six hours are omitted. Stable
provider session IDs deduplicate the fallback with hook sessions. Once an
official hook or managed adapter emits an event for a session, structured events
remain authoritative across helper restarts and transcript timing can no longer
change that session state.

## Consequences

Codex and Claude Code sessions appear without requiring hook installation, while
approval, question, usage and provider-acknowledgment capabilities still require
their structured integration. This is not terminal scraping, screen capture or
UI inference; unsupported decisions remain unavailable.
