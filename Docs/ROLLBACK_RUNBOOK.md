# Rollback and emergency disable

Use a feature disable for isolated pairing, envelope write, APNs, or Live
Activity faults. Use release rollback for crashes, migration, signing, helper
compatibility, or authorization regression. Suspected breaches are SEV-1.

## Emergency disable

1. Select one default-off flag from `Config/Operations/emergency-disable.json`.
2. Record incident/reviewer, apply through deployment config, and roll relay.
3. Confirm health, reads, account deletion, and the documented fallback.
4. Verify the affected write is 503 while unrelated paths pass.
5. Restore only after canary, two-person review, and 30 green minutes.

## Service/client rollback

Deploy the previous immutable relay digest; never destructively roll back the
database. Verify forward schema compatibility, pending fetch, deletion, and one
provider-acknowledged decision. For storage damage use the recovery runbook.

Pause Sparkle stable and App Store phased release. Restore a prior notarized
appcast only after signature/checksum/helper/database compatibility checks. App
Store builds need a higher fixed build. Retain dSYMs/evidence and add regression
coverage before resuming.
