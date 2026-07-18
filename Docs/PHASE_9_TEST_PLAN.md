# Phase 9 Test Plan

Phase 9 covers rules, duration alerts, narrow low-risk automation, history,
analytics, diagnostics, privacy settings, retention, and deletion.

## Automated evidence

- `OperationsRuleEngineTests`: fixed-clock long-running/idle/wait rules and the
  fail-closed automation boundary for medium, high, critical, commands, and
  disabled or unmatched rules.
- `Phase9OperationsTests`: rule/privacy round trips, literal history search,
  analytics aggregates, cascading completed-history deletion, database health,
  and secret-safe diagnostic export.
- `Phase9RuntimeTests`: helper-owned automatic low-risk decision and typed IPC
  endpoints for rules, privacy, diagnostics, and repairs.
- `PerformanceFixtureTests`: with `AGENTCONTROL_RUN_PERFORMANCE_TESTS=1`, writes
  100,000 events and requires the indexed analytics query to complete within
  two seconds on release-test hardware.
- `test_phase9_contract.sh`: source, localization, security guard, chart, IPC,
  and documentation contract.

## Manual release gates

1. Create each alert type and confirm one notification per active rule/session.
2. Confirm a high and critical fake approval cannot be auto-approved even after
   editing stored rules.
3. Exercise history filters, VoiceOver, keyboard navigation, chart labels, and
   English/Turkish UI.
4. Export diagnostics containing provider credential fixtures and scan both the
   JSON and raw bytes for the fixtures.
5. Apply retention, delete completed history, restart the helper, and confirm
   active sessions plus append-only audit records remain intact.

Phase 9 must remain pending verification until these manual checks and the
earlier phase release gates have evidence tied to a commit SHA.
