# Phase 17 test plan

Automated gates cover typed feature dependencies/disable precedence, explicit
diagnostic consent/redaction, bounded authenticated relay/APNs metrics,
default-off emergency controls, cascading account deletion/token invalidation,
compatibility/dashboard/policy/runbook contracts, and eight mandatory release
gates.

Run `make test`, `make relay-test`, and `make operations-verify`.

Protected gates exercise each flag in staging, import dashboard/alerts, inspect
a real support bundle, and delete a paired physical-device account. Collect
exact-build local-only, companion E2E, clean-Mac notarization/update,
TestFlight/App Store, and zero Critical/High evidence. The evidence must pass
`verify_phase17.rb --release-evidence`; structural success cannot promote 1.0.
