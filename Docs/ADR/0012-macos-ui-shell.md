# ADR 0012: Native macOS UI shell

- Status: Accepted
- Date: 2026-07-18

## Context

AgentControl needs a lightweight, always-available surface and a larger
operations view without duplicating helper state or losing the last useful
snapshot during an XPC interruption.

## Decision

Use SwiftUI `MenuBarExtra` for the status entry, an `NSPanel` coordinator for
the floating card, and `NavigationSplitView` for the dashboard. A main-actor
observable store consumes an `AgentControlTransport`; the production transport
wraps XPC requests and notification `AsyncStream` values. The store retains its
last snapshot while offline and refreshes it after reconnect.

Panel placement is computed from display geometry and constrained to the
selected display's visible frame. The panel joins every Space and can appear
beside fullscreen apps. Motion, status, and risk presentation are centralized.

## Consequences

- UI behavior can be tested with an in-memory transport and pure geometry.
- Menu bar, panel, and dashboard share one source of truth.
- XPC remains the authority for session and decision state.
- Detailed approval, question, and notification workflows remain Phase 8.
