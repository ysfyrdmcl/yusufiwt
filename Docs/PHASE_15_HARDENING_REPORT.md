# Phase 15 hardening report

Date: 2026-07-18  
Status: Implemented; release-device, staging and signed-build evidence pending.

## Threat and external-style security review

| Boundary | Abuse case | Control/evidence | Result |
|---|---|---|---|
| Hook/config | symlink swap, parent symlink, injected TOML/key | component `lstat` rejects user-controlled links, regular-file/owner checks, bounded identifiers and JSON-compatible TOML escaping; Phase15 config tests | Pass |
| Local IPC | malformed length/version/type/checksum/random bytes | bounded frame codec plus deterministic 2,000-input and byte-mutation corpus | Pass |
| Companion crypto | oversized ciphertext/QR, retired key, replay/revoke | pre-decode bounds, signature/expiry/replay checks, rotation and revoke drills | Pass |
| Relay | forged direction, replay, revoked device, APNs/Redis outage | role/signature/sequence checks; PostgreSQL pending fetch stays authoritative | Pass |
| Persistence | crash, corrupt pages, failed migration | WAL transaction test, integrity check, backup/restore and read-only salvage runbook | Pass |
| Privacy | plaintext relay/log, undeclared collection/reason API | E2E ciphertext tests, no collection/tracking, CA92.1 UserDefaults declaration | Pass |
| Supply chain | unpinned transitives or missing inventory | resolved revisions and checked-in CycloneDX SBOM | Pass |

Checklist: authentication and authorization are server-side; companion cannot
be execution authority; Critical approval fails closed; all network and local
inputs are bounded; secrets are absent from source/log fixtures; errors do not
return secret material; configuration writes are previewed, atomic and backed
up; refresh tokens rotate/revoke; security headers/rate limits and dependency
inventory are present. No known open Critical/High defect was found in this
review. A newly discovered Critical/High issue blocks release.

## Reliability and performance budgets

| Scenario | Budget/gate |
|---|---|
| Local event round-trip p95 | < 500 ms |
| 100 sessions / 100k events ingestion | < 120 s on release test hardware |
| 100k-event analytics query | < 2 s |
| UI first useful render | < 1 s; no synchronous database open/migration on MainActor |
| Idle memory growth | < 5 MB over 30 minutes and zero persistent leak cycles |
| Idle energy | Instruments Energy Impact Low; no continuous polling while disconnected/backgrounded |
| Network outage | local agent flow remains available; pending reconciliation recovers without loss |

The automated performance fixture enforces the storage budgets. Before RC sign
off, capture release-build Time Profiler, Allocations/Leaks and Energy Log traces
for idle, 100-session ingest, decision round-trip and reconnect. Record hardware,
OS, build SHA, p50/p95, peak/steady memory and trace paths in the Phase 15 test
record. A miss requires a blocking ADR with owner and mitigation.

Automated evidence on 2026-07-18: the 100-session/100k-event fixture completed
in 10.297 seconds on the current Apple Silicon development Mac; its internal
ingestion (<120 s) and analytics (<2 s) assertions passed.

The macOS app/helper/hook/simulator/inspector Xcode smoke targets also built.
The combined iOS/Watch smoke is environment-blocked because this Xcode install
does not include the watchOS 26.5 platform; it remains an RC verification item,
not a documented performance-budget exception.

## Accessibility and localization audit

Critical Mac and iPhone decision flows expose labels/hints, keyboard default and
cancel actions, non-color status text, Dynamic Type layouts and Reduce Motion.
`Scripts/verify_phase15.sh` rejects incomplete English/Turkish catalogs and
missing critical accessibility hooks. RC device QA still covers VoiceOver focus
order, Switch Control, Full Keyboard Access, 200% text, Reduce Motion/Transparency,
RTL stress and Turkish truncation on smallest supported screens.

## Memory and energy changes reviewed

Database work remains actor-isolated/off the main executor; retention is bounded;
XPC reconnect uses capped backoff; companion pending fetch is user/app lifecycle
driven; APNs and Live Activity are advisory; activities are reconciled/staled;
Watch payloads are bounded. No new timer or unbounded cache was introduced.
