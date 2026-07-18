# Phase 14 test plan

## Automated gates

- `swift test --disable-sandbox --package-path Packages/AgentControlKit --filter AgentCompanionTests`
  - glanceable snapshots stay within 4 KB and omit request detail;
  - Watch approves Low only and hands off Medium/High/Critical;
  - Watch message codec rejects oversized messages;
  - activity final/stale semantics are deterministic.
- `swift test --disable-sandbox --package-path Services/AgentControlRelay`
  - only iPhone registers a Live Activity token;
  - token ciphertext contains no plaintext token;
  - only the paired local Mac can request an update;
  - update is routed to the dedicated Live Activity provider.
- `Tests/Contracts/test_phase14_contract.sh`
  - ActivityKit, widgets, WatchConnectivity, entitlements, APNs topic and risk gates remain wired.
- Xcode gates:
  - iOS scheme builds with Live Activity and widget extensions;
  - Watch app type-checks/builds with strict concurrency;
  - English/Turkish catalogs are structurally complete.

## Physical-device and staging gates

1. Pin session A, then session B; verify only B remains on Lock Screen/Dynamic Island.
2. Update running → waiting approval → completed/failed through staging Live Activity APNs and verify state, elapsed time and final dismissal.
3. Stop updates for fifteen minutes and verify the activity ends automatically on the next reconciliation/stale event.
4. Verify Live Activity and both widgets expose no direct Approve/Deny control and deep-link to AgentControl.
5. Verify active count, pending approval count and last completed task refresh after foreground/background sync.
6. Pair a physical Watch and verify inbox priority, completion/failure states and WatchConnectivity recovery after iPhone disconnection.
7. Approve an unexpired Low request on Watch and verify the iPhone queues it, the Mac revalidates it and success appears only after provider acknowledgment.
8. Verify Medium/High/Critical Approve always opens iPhone; Critical Deny remains available.
9. Lock the Watch, revoke the companion, expire/supersede a request and confirm no Watch action is applied.
10. Capture APNs requests and database/log output; confirm the activity token is encrypted and no prompt, command, path or request detail is present.

Phase 14 is not `Verified` until automated gates, physical-device/staging gates and a commit SHA are recorded.
