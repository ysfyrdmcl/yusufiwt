# yusufiwt release runbook

## One-time protected environment setup

1. Install the Developer ID Application and Apple Distribution certificates in
   a temporary CI keychain. Never commit certificate exports or passwords.
2. Store notarization credentials under a `notarytool` Keychain profile, or
   create that profile from a protected App Store Connect API key during the job.
3. Generate the Sparkle Ed25519 key with Sparkle's `generate_keys`. Commit only
   the printed public key through the protected build input; keep/export the
   private key only in Keychain or the CI secret store.
4. Configure the App Store Connect application, bundle IDs, APNs, Sign in with
   Apple, app group, keychain group, Live Activity, widgets, and Watch profiles.

## macOS stable/beta

```sh
RELEASE_VERSION=1.0.0 BUILD_NUMBER=100 RELEASE_CHANNEL=stable \
AGENTCONTROL_TEAM_ID=TEAMID \
DEVELOPER_ID_APPLICATION='Developer ID Application: Example (TEAMID)' \
NOTARY_KEYCHAIN_PROFILE=agentcontrol-notary \
SPARKLE_PUBLIC_ED_KEY='base64-public-key' \
SPARKLE_PRIVATE_KEY_FILE=/protected/sparkle-private-key \
Scripts/release_macos.sh
```

Use `RELEASE_CHANNEL=beta` for the staged beta feed. The script archives,
exports, notarizes, staples, packages ZIP/DMG, signs the appcast, retains dSYMs,
emits SBOM/checksums, and runs the strict verifier. Setting
`AGENTCONTROL_SKIP_NOTARIZATION=1` creates a clearly marked local artifact that
must never be uploaded or added to an appcast used by customers.

Publish the contents of `feed/<channel>` atomically over HTTPS only after the
verifier report passes. Retain the `.xcarchive`, dSYM ZIP, notary JSON, SBOM,
checksums, and report under the matching commit/build record.

## iOS/watchOS and TestFlight

```sh
RELEASE_VERSION=1.0.0 BUILD_NUMBER=100 AGENTCONTROL_TEAM_ID=TEAMID \
ASC_KEY_PATH=/protected/AuthKey_KEYID.p8 ASC_KEY_ID=KEYID \
ASC_ISSUER_ID=ISSUER Scripts/release_ios.sh upload
```

Run without `upload` to export an IPA locally. The archive verifier checks
production push and companion entitlements, embedded extensions/watch app, and
dSYMs before export/upload.

## Mandatory release evidence

- Commit SHA, version/build, release channel, verifier report, checksums, SBOM.
- Apple notarization IDs and successful staple/Gatekeeper output.
- Clean-Mac install plus previous-stable-to-current Sparkle update smoke.
- TestFlight build ID and physical iPhone/Watch pairing/push/decision smoke.
- Database migration, helper re-registration, and post-update approval result.

If any check fails, do not mutate an existing published appcast. Fix the issue,
increment the build number, produce new artifacts, and repeat all gates.
