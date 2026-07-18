# Phase 1 Test Plan

Phase 1 establishes the deterministic domain and wire contracts. Persistence,
IPC, provider adapters, and UI are outside this phase.

## Required coverage

- Every session-state transition pair, including explicit provider resume.
- Every approval lifecycle edge; applied states require provider acknowledgment.
- Duplicate and out-of-order event behavior.
- Unknown event forward compatibility.
- Multiple pending approvals and independent parent/subagent lifecycles.
- Strong identifier type separation and Codable round trips.
- Versioned envelope backward/forward tolerance and size limits.
- Risk fixtures covering path scope, privilege, network, destructive behavior,
  shell ambiguity, secrets, production deploy, and protected force-push.
- Critical risk must never be remotely approvable.

## Acceptance

`make test` must pass. The domain target must not import Apple UI, networking, or
persistence frameworks. Critical state and risk branches are expected to have
complete test coverage; overall domain line coverage target is at least 90%.

