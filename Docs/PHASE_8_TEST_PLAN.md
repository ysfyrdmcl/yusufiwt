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
- stable-ID single-choice and multi-choice answers;
- capability-bounded free text and confirmation payloads;
- plan Approve / Request Changes / Deny payload separation;
- notification callback rejection for duplicate, expired, superseded, and
  secret-response attempts;
- notification permission denial degrading without blocking the inbox.

The Phase 8 contract verifies the approval/question/plan UI, notification
categories, grouping, quiet/focus policy, expiry checks, bilingual strings,
and the documented acknowledgment boundary.

## Manual smoke test

1. Run Fake Agent Simulator with parallel approval, question, and plan requests.
2. Confirm each request appears once and expired actions are disabled.
3. Inspect a command request; confirm executable, arguments, working directory,
   risk level, and risk reasons are visible.
4. Answer single-choice, multi-choice, free-text, and confirmation questions.
   Confirm choice decisions contain IDs rather than labels and a secret question only offers
   **Open Terminal** and its prompt cannot be answered from a notification.
5. Accept, request changes to, and deny a plan. Request Changes text must not
   appear as a command approval decision.
6. Enable quiet hours and a Focus mode; confirm notifications remain grouped by
   session, do not bypass Focus, and play no sound during quiet hours.
7. Resolve a request and confirm the UI says it was sent to the provider, not
   applied, until a provider acknowledgment event is received.

AgentControl uses only public UserNotifications category and interruption APIs.
macOS, not AgentControl, applies the user's Focus configuration. The app's own
quiet-hours policy is independently tested with a deterministic clock.

## Commands

```sh
Tests/Contracts/test_phase8_contract.sh
./Scripts/test_swift.sh
./Scripts/test_all.sh
```
