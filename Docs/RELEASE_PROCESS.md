# Release Process

Mac Local V1 uses `make test-mac-local`, `make build-mac-local`, `make package-mac-local` and `make verify-mac-local-v1`. Its artifacts are an ad-hoc or development-signed `.app`, ZIP and SHA-256 manifest under `dist/`. Developer ID notarization and Sparkle publishing are not applicable to this release.

The existing App Store, TestFlight, Developer ID, Sparkle and relay release automation is preserved for V2 and is not invoked by the Mac Local gate.
