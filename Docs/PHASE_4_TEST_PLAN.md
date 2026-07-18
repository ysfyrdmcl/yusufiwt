# Phase 4 Test Plan

Phase 4 proves the local event and synchronous decision path before any real
provider adapter is installed.

## Automated coverage

- Real Unix-domain socket approval round-trip through the helper decision broker.
- Native-prompt neutral fallback and owner-only atomic event spool when the helper is absent.
- Decision revision, expiry, question-choice, and shutdown validation.
- 1 MiB input limit, malformed JSON, and 64-level nesting rejection.
- Running, progress, approval, question, plan, subagent, completion, failure,
  malformed, duplicate, and out-of-order simulator fixtures.
- Forty local socket event round-trips with p95 below the 500 ms hard limit.
- All three Phase 4 tools compile as SwiftPM and Xcode targets.

## Manual smoke test

Start `AgentControlHelper` with a temporary `AGENTCONTROL_*` path set, then run:

```sh
swift run fake-agent-simulator approval
swift run protocol-inspector pending
swift run protocol-inspector resolve REQUEST_ID 1 approve
```

The simulator must print exactly one JSON decision response to stdout. Stop the
helper and repeat; the simulator must print a neutral result and the event must
remain in the spool. `agentcontrol-hook version` must emit no stderr output.

Fake Agent Simulator and Protocol Inspector are development tools and are not
embedded in the signed application product.
