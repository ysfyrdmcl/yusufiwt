# Phase 17 implementation report

- Date: 2026-07-18
- Status: Implemented, pending protected 1.0 release-gate evidence

Implemented: internal-alpha rollout policy, emergency disables, authenticated
bounded metrics, operations dashboard contract, adapter matrix/local-only
evidence, consent-gated feedback package, account deletion UI/API cascade, beta
notes/issues, privacy/support/deletion policies, incident/rollback/checklist,
ADR, structural verifier, and automated tests.

This does not claim a stable release. Notarization, clean-Mac update,
TestFlight/App Store, physical iPhone/Watch/APNs, live dashboard/incident drills,
and Critical/High sign-off need protected external evidence for the exact
candidate. `verify_phase17.rb --release-evidence` rejects missing gates.

## Local evidence

- All 148 root Swift tests pass; AgentDomain coverage is 92.12% and
  RiskClassifier coverage is 100%.
- All 12 relay security/operations tests pass, including account deletion and
  token invalidation.
- All repository/phase contract tests pass; the Phase 17 verifier reports 31
  checks.
- SwiftFormat and SwiftLint pass with zero violations across 150 files.
- macOS app/helper/hook/simulator/inspector targets build.
- The iOS app plus Notification Service, Live Activity and Widget extensions
  builds after omitting only the Watch embed dependency for this local smoke.
  The normal combined scheme remains blocked because watchOS 26.5 is not
  installed; the project was regenerated with the Watch dependency restored.
