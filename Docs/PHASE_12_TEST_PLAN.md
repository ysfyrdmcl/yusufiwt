# Phase 12 test plan

## Automated gates

- `swift test --disable-sandbox --filter AgentCompanionTests`
  - X25519/HKDF agreement and matching fingerprint.
  - ChaChaPoly encrypted Mac/companion round trip.
  - Ed25519 tamper rejection, expiry, replay and Critical/Watch policy boundaries.
- `cd Services/AgentControlRelay && swift test --disable-sandbox`
  - invalid Apple token and access/refresh rotation.
  - one-local-Mac registry rule, expired pairing and revoke.
  - wrong recipient, tampered signature, duplicate/replayed sequence and rate limit.
  - WebSocket-loss pending fetch reconciliation and APNs invalid-token handling.
- `Tests/Contracts/test_phase12_contract.sh`
  - Vapor/PostgreSQL/Redis/Docker deliverables exist.
  - no remote-node/SSH executable or companion execution API exists.
  - stored envelope schema contains ciphertext and routing metadata, not prompt/path/command fields.

## Manual staging gates

1. Verify a real Sign in with Apple token against Apple JWKS, including key refresh and wrong audience.
2. Pair one Mac and iPhone, compare the short fingerprint on both devices, then exchange an encrypted fixture.
3. Disconnect WebSocket, enqueue an envelope, reconnect and confirm pending cursor reconciliation.
4. Revoke the iPhone while connected; confirm the socket closes or its next operation fails and refresh cannot recover it.
5. Exercise APNs sandbox success, `BadDeviceToken`, `Unregistered`, 429 and 5xx paths.
6. Inspect PostgreSQL, Redis and structured logs using prompt/path/command canaries; no plaintext canary may appear.
7. Confirm a second active Mac registration conflicts and no route starts an agent/process.

Phase 12 is not `Verified` until automated gates, the manual staging gates and a commit SHA are recorded.
