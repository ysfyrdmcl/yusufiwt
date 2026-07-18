# ADR 0016 — Phase 10 navigation and onboarding boundary

## Status

Accepted for implementation; release verification remains gated by live
terminal/IDE smoke tests and the earlier phase evidence in the project plan.

## Decision

`TerminalContext` is captured from structured hook fields and narrowly named
environment variables. Unknown terminal programs produce no invented context.
The correlation token is opaque and terminal output is never inspected.

The macOS navigation planner has a fixed degradation order: an official
extension/API or URL, permission-gated AppleScript, opt-in Accessibility,
application activation, then project-folder opening. Every result reports its
actual level (`exactPane`, `window`, `application`, `projectFolder`, or
`unsupported`). AppleScript and CLI values are passed as process arguments;
there is no shell interpolation. Normal navigation performs non-prompting TCC
checks. Only an explicit onboarding button may request permission. VS Code and
Cursor report their actual reveal/fallback level through AgentControl's callback
URL; dispatching an extension URL alone is never treated as exact-pane success.

Hook onboarding is preview-first. All selected provider files are validated
before the first write, and the low-level integration actor rolls back prior
writes if a later write fails or cancellation is observed. Uninstall patches
the current configuration and removes only entries containing AgentControl's
unique markers. Backup restore requires the current file hash to match the
recorded post-install hash and therefore cannot erase an external edit.

Remote working modes may be selected and remembered, but Phase 10 completes
only their local setup. Authentication, pairing, and relay activation remain
owned by Phases 12 and 13.

## Consequences

- Missing permissions are capabilities, not crashes or repeated system prompts.
- Ghostty exact focus requires its AppleScript surface, WezTerm uses its pane
  CLI, Warp opens a workspace because it has no documented existing-pane URI,
  and VS Code/Cursor use the bundled extension protocol.
- Interrupted onboarding cannot leave a partially installed multi-file change.
- Exact-pane behavior still requires signed-app manual smoke tests against the
  supported terminal versions before the phase can be marked verified.
