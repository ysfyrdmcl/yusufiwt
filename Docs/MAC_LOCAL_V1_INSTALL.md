# yusufiwt macOS Local V1 — Install

## Requirements

- macOS 14 or newer
- Apple Silicon or Intel Mac
- Local user access to `/Applications`

## Build from source

Run `make bootstrap`, `make generate`, `make test-mac-local`, then `make
package-mac-local`. Artifacts are written under `dist/`.

## Install

1. Extract `yusufiwt-macOS-local-v1.zip`.
2. Move `yusufiwt.app` to Applications and open it.
3. Allow background activity/notifications when macOS requests them.
4. If Codex is already open without a control connection, approve the in-app
   reopen prompt after finishing ongoing work. yusufiwt handles the restart.

No Terminal command is required. The included installer remains an optional
alternative for scripted installation.

For an ad-hoc artifact, Gatekeeper may require the user-controlled Finder path
**Control-click → Open** on first launch. The installer never removes quarantine
attributes. In System Settings → Notifications → yusufiwt, enable notifications
if they were previously denied.

The ad-hoc development artifact uses a same-user LaunchAgent because macOS does
not permit an ad-hoc executable through `SMAppService`. Apple Development and
Developer ID builds use the in-app ServiceManagement registration path.

## Provider hooks

Open Control Center → Integrations to install or repair managed provider hooks.
The app previews configuration changes, backs up the original, and changes only
its managed entries. Codex transcript monitoring and account usage work without
installing hooks.

## Upgrade

### Codex desktop task control

The default desktop process may use private stdio, which cannot be attached to
by another app. Monitoring and opening `codex://threads/<id>` work without a
control connection. To enable stopping through the desktop relay:

Open yusufiwt. It starts Codex with the bundled relay automatically when Codex
is closed. If Codex is already running without the relay, an in-app prompt asks
to reopen it; yusufiwt performs the graceful restart and verifies the connection.
It never force-quits Codex. Declining keeps monitoring available.

The environment applies only to that Codex launch. No global environment or
credentials are changed. The relay uses the
[official `turn/interrupt` protocol](https://learn.chatgpt.com/docs/app-server).
An acknowledgment is separate from confirmed task completion.

The header reads the connected Codex account's weekly used percentage through
`account/rateLimits/read` once per minute, even with no active tasks. Each row
shows context used from that conversation's latest token usage and context
window, independently of account quota. Missing values are never shown as zero.
Idle/unknown records are excluded from working counts; abandoned running
transcripts become stale after five minutes without writes. Persisted working
records without new events expire after twenty minutes, preserving history.

### Replace the installed build

Run the new archive's `install_mac_local.sh`. Installation stages and verifies
the replacement before swapping it into `/Applications`. Local history and
pending spool files are preserved.

## Uninstall

Run `./uninstall_mac_local.sh`. This removes the app and helper registration but
preserves local history. From the repository, `PURGE_DATA=1 make
uninstall-mac-local` also removes `~/Library/Application Support/AgentControl`.
That legacy internal data directory is intentionally retained so existing local
history survives the product rename.

## Recovery

- `agentcontrol-hook doctor`: helper/socket/database status.
- `agentcontrol-hook managed-preview <codex|claude|gemini|cursor>`: show provider edits.
- `agentcontrol-hook managed-repair <codex|claude|gemini|cursor>`: repair only owned blocks.
- Re-run the installer if helper health is unavailable.
