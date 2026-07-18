# ADR 0019 — Phase 14 glanceable surface boundary

## Status

Accepted for Phase 14.

## Decision

Live Activity, widgets and Apple Watch consume a bounded companion snapshot rather than the full inbox or session payload. The snapshot is capped at 4 KB, limits each visible list to five entries, truncates display labels and never includes request detail, command, path, prompt or code. Widgets read this snapshot from the iPhone App Group; Watch receives the same value through `WatchConnectivity`.

Only one session may be selected for Live Activity. Selecting another session ends the previous activity. Terminal activities show their final state briefly; missing, explicitly stale or fifteen-minute-old sessions end automatically. Live Activity and widgets only deep-link into AgentControl and cannot create approval decisions.

The iPhone registers the selected ActivityKit push token with the relay. Tokens are encrypted at rest, scoped to the authenticated iPhone and session, expire within eight hours and are never logged. A local-Mac authority may submit only a validated session state and timestamps. The relay forwards the small `content-state` through the dedicated Live Activity APNs topic; agent/project names stay in locally created ActivityKit attributes.

Watch decisions travel to the iPhone over `WatchConnectivity`; Watch never holds relay authority or calls an agent provider. Approve is allowed only for an unexpired Low-risk request. Medium, High and Critical approvals hand off to iPhone. Deny is allowed for any current request. The iPhone re-resolves request ID/version and re-runs companion policy before signing or queuing a decision.

## Consequences

- A glanceable surface cannot leak full agent content or bypass the Mac acknowledgment boundary.
- Live Activity APNs payloads contain state/timestamps only; routing metadata and encrypted tokens remain short-lived.
- Watch connectivity failure cannot silently apply a decision; the user is asked to continue on iPhone.
- Simulator and unit tests cover contracts, but physical iPhone/Watch and staging APNs tests remain release gates.
