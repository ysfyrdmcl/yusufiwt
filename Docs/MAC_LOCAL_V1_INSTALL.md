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
2. In Terminal, run `./install_mac_local.sh` from the extracted folder.
3. Complete notification/background-item approval if macOS requests it.
4. Confirm health from the repository with `make verify-mac-local-v1`, or run:
   `/Applications/yusufiwt.app/Contents/MacOS/agentcontrol-hook doctor`

For an ad-hoc artifact, Gatekeeper may require the user-controlled Finder path
**Control-click → Open** on first launch. The installer never removes quarantine
attributes. In System Settings → Notifications → yusufiwt, enable notifications
if they were previously denied.

The ad-hoc development artifact uses a same-user LaunchAgent because macOS does
not permit an ad-hoc executable through `SMAppService`. Apple Development and
Developer ID builds use the in-app ServiceManagement registration path.

## Provider hooks

Preview before changing any configuration:

```sh
/Applications/yusufiwt.app/Contents/MacOS/agentcontrol-hook managed-preview codex
/Applications/yusufiwt.app/Contents/MacOS/agentcontrol-hook managed-install codex
```

Replace `codex` with `claude` or `gemini`. Installation is atomic, backs up the
original, and changes only yusufiwt-managed entries. Use `managed-repair` or
`managed-uninstall` with the same provider name for recovery.

## Upgrade

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
- `agentcontrol-hook managed-preview <codex|claude|gemini>`: show provider edits.
- `agentcontrol-hook managed-repair <codex|claude|gemini>`: repair only owned blocks.
- Re-run the installer if helper health is unavailable.
