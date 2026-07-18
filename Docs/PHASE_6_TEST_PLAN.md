# Phase 6 Test Plan

Phase 6 connects existing Codex, Claude Code, and Gemini CLI terminal sessions
to the normalized local protocol. Provider hooks invoke `agentcontrol-hook
provider-hook <provider>` over stdin/stdout. A missing helper always returns an
empty provider response, preserving the provider's native prompt path.

## Automated coverage

- Lossless JSON/JSONC hook insertion and scoped removal, including comments,
  unrelated fields, existing hooks, empty files, duplicate repair, malformed
  input, symlinks, backups, and concurrent edits.
- TOML managed blocks with stable begin/end markers and idempotent uninstall.
- User-level hook matrices for Codex, Claude Code, and Gemini CLI.
- Binary/version parsing and capability selection. Unknown majors expose only
  `monitorSessions`; they cannot return automatic allow decisions.
- Fixture matrices for started, progress, waiting approval, completed, and
  provider-specific decision output.
- Claude Elicitation choice response; secret-shaped questions stay local and
  never create a remote decision request.
- Auto-review modes are recorded but filtered from approval prompts.

Run focused coverage with:

```sh
swift test --filter Phase6AdapterTests
./Tests/Contracts/test_phase6_contract.sh
```

## Manual smoke test

For each detected provider, preview and install the user-level hook file, then
review the exact diff before applying. Start a disposable session and verify
start, tool progress, permission wait, deny/approve where the provider supports
it, and completion. Stop the helper and repeat a permission request: the native
provider prompt must still appear. Edit an unrelated comment and hook, run
repair, then uninstall AgentControl; both user edits must remain unchanged.

Codex non-managed hooks must be reviewed in `/hooks` before they run. Gemini
Notification hooks are observability-only, so permission decisions are only
attempted for synchronous `BeforeTool` input that explicitly identifies an
approval boundary.
