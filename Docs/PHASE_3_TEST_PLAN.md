# Phase 3 Test Plan

Phase 3 establishes the user-level helper as the local authority and covers its
LaunchAgent lifecycle, authenticated XPC, bounded Unix socket, spool fallback,
session registry, health, restart, and update handoff.

## Automated coverage

- XPC authorization accepts only the expected UID, bundle identifier, and team.
- Debug ad-hoc signature acceptance is explicit and disabled by default.
- `NSSecureCoding` XPC wrappers round-trip and reject oversized payloads.
- Reconnect backoff is exponential and capped.
- Socket frames validate magic, version, type, size, checksum, completeness,
  and absence of trailing data.
- Real same-user Unix socket requests round-trip with filesystem mode `0600`.
- Wrong-user peer fixtures are rejected by the same policy used by the server.
- 100 concurrent health requests exercise socket backlog and backpressure.
- Helper-unavailable calls return neutral fallback rather than approval.
- Spool failures remain queued; successful imports are removed.
- Events persist without an app client and duplicates do not reapply snapshots.
- Active snapshots restore after database/helper restart.
- Health, heartbeat, version negotiation, update handoff, and graceful shutdown
  return typed states.
- LaunchAgent unregister is idempotent and removes only owned socket, handoff,
  and private spool artifacts; it never deletes the event database.

## Manual signed-build check

Before distribution, build the signed macOS app, confirm the helper and plist
exist under `Contents/MacOS` and `Contents/Library/LaunchAgents`, register via
`LaunchAgentManager`, and verify an unrelated signed process is denied by the
live Mach service. Automated tests use deterministic signature fixtures because
CI artifacts may be ad-hoc signed.

`SMAppService.unregister()` removes the registered service. The source plist is
an app-bundle resource and disappears when the signed app bundle is uninstalled;
AgentControl never mutates or deletes an arbitrary external plist.

## Acceptance

`make test` and `make lint` must pass. Unix socket integration tests require a
test environment that permits local socket creation; the Codex filesystem
sandbox blocks `bind(2)` with `EPERM`, so the full acceptance command is run
outside that sandbox.
