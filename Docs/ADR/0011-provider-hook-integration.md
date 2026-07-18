# ADR 0011: Provider hook integration and managed config patches

- Status: Accepted
- Date: 2026-07-18

## Decision

Existing terminal sessions use provider-owned lifecycle hooks and the shared
`agentcontrol-hook` executable. Codex uses its user-level `hooks.json`; Claude
Code and Gemini CLI use their user settings JSON. The installed commands carry
the detected provider version. A missing or unknown version is monitor-only.

JSON and JSONC files are patched in place at the hook array boundary instead of
being decoded and reserialized. This preserves comments, ordering, whitespace,
and unrelated settings. TOML uses stable managed begin/end blocks. Every write
requires preview, ownership/symlink checks, a same-filesystem temporary file,
fsync, atomic replacement, backup rotation, and a concurrent-edit comparison.
Uninstall removes only entries containing AgentControl's unique marker.

Permission and question responses are provider-specific JSON emitted only after
the helper returns an explicit decision. Helper timeout, helper absence,
auto-review modes, unsupported hook events, and unknown provider versions all
produce a neutral empty object. They never produce `allow`.

## Consequences

- Provider-native prompts remain the fail-open interaction path when the helper
  is unavailable, while AgentControl itself never silently approves.
- Capability UI can use the normalized matrix rather than provider-name checks.
- A provider schema/version change degrades to monitoring until its fixtures and
  compatibility policy are deliberately updated.
