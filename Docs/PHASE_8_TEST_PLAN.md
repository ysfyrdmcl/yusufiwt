# Phase 8 Test Plan

## Automated acceptance coverage

`AgentMacUITests` verifies:

- duplicate request collapse while preserving the newest revision;
- expiry enforcement before a decision reaches the transport;
- secret-question terminal fallback;
- quiet hours spanning midnight and sound policy;
- notification duplicate suppression per request revision;
- parsed command and deterministic risk-reason presentation;
- local acknowledgment stopping at `sentToProvider`, never `applied`.

The Phase 8 contract verifies the approval/question/plan UI, notification
categories, grouping, quiet/focus policy, expiry checks, bilingual strings,
and the documented acknowledgment boundary.

## Manual smoke test

1. Run Fake Agent Simulator with parallel approval, question, and plan requests.
2. Confirm each request appears once and expired actions are disabled.
3. Inspect a command request; confirm executable, arguments, working directory,
   risk level, and risk reasons are visible.
4. Answer choice and text questions. Confirm a secret question only offers
   **Open Terminal** and its prompt cannot be answered from a notification.
5. Accept and deny a plan from the dashboard and notification actions.
6. Enable quiet hours and a Focus mode; confirm notifications remain grouped by
   session, do not bypass Focus, and play no sound during quiet hours.
7. Resolve a request and confirm the UI says it was sent to the provider, not
   applied, until a provider acknowledgment event is received.

## Commands

```sh
Tests/Contracts/test_phase8_contract.sh
./Scripts/test_swift.sh
./Scripts/test_all.sh
```
