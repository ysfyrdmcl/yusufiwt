# Phase 16 test plan

## Automated contract gates

- Release configuration enables Hardened Runtime and `dwarf-with-dsym`, uses
  monotonic build-number substitutions, and never enables `get-task-allow`.
- XcodeGen embeds the signed helper/hook and generates a compatibility manifest
  containing their SHA-256 digests.
- Sparkle is linked only to the macOS application; `SUFeedURL` is HTTPS and the
  release verifier requires a 32-byte base64 Ed25519 public key.
- macOS archive/export, ZIP/DMG packaging, notarization/stapling, appcast signing,
  SBOM/checksum, and dSYM retention are wired through one fail-closed script.
- iOS/watchOS archive and TestFlight upload use production APNs and verify all
  companion bundle IDs and required entitlements before upload.
- `Scripts/verify_release.rb --structural` and shell syntax checks pass without
  release credentials. Artifact verification has no network dependency.

Run:

```sh
./Tests/Contracts/test_phase16_contract.sh
```

## Protected release-environment gates

1. Run `Scripts/release_macos.sh` with Developer ID, notarization, and Sparkle
   signing credentials. Preserve the `.xcarchive`, dSYMs, verifier report, SBOM,
   checksums, appcast, ZIP, and DMG.
2. On a clean supported Mac, download the DMG over HTTPS, verify `spctl` accepts
   it, install into `/Applications`, launch, register the helper, and complete one
   fake-agent approval round trip.
3. Install the previous stable build, publish the new build to a temporary stable
   feed, trigger “Check for Updates…”, and verify app replacement, database
   migration, helper re-registration, and an approval round trip after restart.
4. Run `Scripts/release_ios.sh upload`, wait for App Store Connect processing,
   install from TestFlight on a physical iPhone with its paired Watch, pair with
   the local Mac, receive a push, approve one Low-risk request, and hand off one
   High-risk request to iPhone.
5. Record the commit SHA, Apple notarization submission ID, TestFlight build ID,
   clean-Mac OS version, and smoke-test result in the release evidence record.

The phase remains “implemented, pending verification” until these protected,
physical-device gates have evidence for the exact release commit.

