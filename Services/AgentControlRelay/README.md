# yusufiwt Relay

Vapor relay for the optional Personal/Self-Hosted Companion modes. It accepts only authenticated routing metadata, public device keys, short-lived pairing material and encrypted envelopes. It never receives agent prompts, commands, paths or content keys.

Only one active `localMac` device is allowed per account. iPhone and Watch devices are companion decision endpoints; they cannot register as an execution authority or send provider acknowledgments.

## Local run

1. Copy `.env.example` to `.env` and replace every `example-required` value.
2. Run `docker compose up --build`.
3. Check `GET http://localhost:8080/v1/health` and `GET /v1/ready`.

For Swift tests, run `swift test --disable-sandbox`. Tests use in-memory SQLite and do not require Apple, APNs, PostgreSQL or Redis credentials.

## Operations

- Rotate access signing keys by deploying the new key, allowing the access-token TTL to elapse, then removing the previous key.
- Device revoke invalidates device authentication and refresh tokens immediately and removes queued envelopes involving that device.
- APNs `BadDeviceToken`/`Unregistered` results delete the token. Rate/server failures remain retryable and pending fetch is authoritative.
- Live Activity tokens are encrypted at rest, scoped to one iPhone/session, expire within eight hours and use `APNS_LIVE_ACTIVITY_TOPIC`; update payloads contain only state and timestamps.
- WebSocket delivery is an optimization. Clients always reconcile with `GET /v1/envelopes/pending?after=<sequence>`.
- Ciphertext is deleted after acknowledgment/expiry by retention cleanup. Database backups remain encrypted at rest and follow the same short retention policy.
- `DELETE /v1/account` cascades devices, credentials, push tokens, pairing sessions and pending ciphertext, then closes active sockets.
- `/internal/metrics` exists only with `METRICS_BEARER_TOKEN`; its bounded labels contain no user, device, token, envelope or payload values.
- Pairing, envelope submission, APNs and Live Activities have independent default-off emergency flags in `Config/Operations/emergency-disable.json`.
- Never enable request-body logging. Authorization, refresh tokens, APNs tokens, database URLs and Apple identity tokens must be redacted by the platform log sink.
