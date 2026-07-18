# Phase 15 test plan

## Automated gates

1. `Tests/Contracts/test_phase15_contract.sh` validates privacy, localization,
   accessibility hooks, recovery drills and SBOM structure.
2. `Scripts/test_swift.sh` runs malformed/fuzz corpora, config injection/symlink,
   crypto rotation/bounds, persistence recovery and all regression tests.
3. `swift test --disable-sandbox --package-path Services/AgentControlRelay` runs
   key rotation/revoke, malformed envelope, network/APNs outage and authoritative
   pending-fetch tests.
4. `Scripts/test_persistence_performance.sh` enforces 100 sessions/100k events,
   120-second ingestion and two-second analytics budgets on release hardware.
5. `Scripts/test_all.sh` is the crash-free macOS/iOS/watchOS/extensions build
   smoke. `make lint` remains mandatory.

## RC manual/staging gates

1. Execute the external checklist in `PHASE_15_HARDENING_REPORT.md`; triage every
   finding and confirm no open Critical/High issue.
2. Rotate iPhone and Mac companion keys, prove retired envelopes/refresh tokens
   fail, then revoke each device and prove access is immediate denied.
3. Partition Mac/iPhone/relay, disable Redis and return APNs 429/5xx for 15
   minutes; local flow must continue and pending fetch must reconcile once.
4. Execute `RECOVERY_RUNBOOK.md` on an encrypted production-shaped copy and
   record hashes, counts, recovery time and lost-event window.
5. Capture Time Profiler, Allocations/Leaks and Energy Log traces for the four
   scenarios and budgets in the hardening report.
6. Run VoiceOver and Full Keyboard Access through inbox → detail → approve/deny,
   secret fallback, offline/error/retry and revoke in English and Turkish.
7. Generate Xcode's archive privacy report, compare it with
   `Config/Privacy/DataUsage.md`, and attach a current advisory scan of the SBOM.

Phase 15 is not `Verified` until automated plus manual/staging gates and a commit
SHA are recorded. A failed performance gate needs a blocking ADR.
