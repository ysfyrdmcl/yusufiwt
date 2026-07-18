# ADR 0017: Single-Mac agent scope

- Status: Accepted
- Date: 2026-07-18

## Context

The product owner wants AgentControl to observe and control agents running on one local Mac. iPhone and Apple Watch should receive notifications and submit bounded decisions for those sessions. Managing agents on additional Mac/Linux machines, SSH bootstrap, and remote execution are not product goals.

The original Phase 11 introduced a remote-node service before the relay and companion phases. That service is not a technical prerequisite for Mac-to-iPhone/watch communication: the existing local Mac helper can be the sole execution authority and relay endpoint.

## Decision

- Agent sessions and provider integrations run only on the Mac where AgentControl is installed.
- Phase 11 remote node and SSH work is skipped.
- Phase 12 connects the local Mac helper directly to paired companion devices through the end-to-end encrypted relay.
- iPhone and Watch may display state and submit policy-bounded signed decisions, but cannot start an agent process or act as an execution node.
- The Mac helper remains the sole authority that validates a decision, applies it to the provider, and reports provider acknowledgment.
- Existing `NodeID` and `nodes` wire/database names may remain for compatibility, but represent the single local Mac only.

## Consequences

- No `AgentControlRemoteNode` executable, SSH credentials, systemd package, remote terminal jump, remote-node UI, or discovery flow is built.
- Relay and mobile security work remains required for notifications and approvals away from the Mac.
- Removing remote-node scope reduces attack surface and implementation/release burden without reducing the requested iPhone/watch experience.

