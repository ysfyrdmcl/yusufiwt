# Privacy

yusufiwt is local-first. Prompt text, source code, terminal output, command
content, full paths, credentials, and secret answers are not retained by
default. The Phase 9 privacy controls keep local analytics enabled by default
while prompt and terminal-output storage remain disabled.

Future fields are classified as public metadata, private metadata, sensitive, or secret. Secret data must not be persisted or relayed outside a required device-local secure path. Telemetry is opt-in and must exclude prompt, code, command, path, and secret content.

History and analytics are computed locally from normalized metadata. Retention
deletes old event rows in bounded transactions; explicit history deletion
cascades through completed sessions while preserving the append-only audit log.
Diagnostic exports omit sensitive/secret attachments, redact credential-shaped
values and user home paths, and include private metadata only after explicit
opt-in.

Terminal navigation stores only the application bundle identifier, opaque
window/tab/pane identifiers, a correlation token, and an optional workspace
URI already present in the local hook environment. yusufiwt does not read
terminal output or use Screen Recording. Accessibility is an opt-in navigation
fallback, and Automation is requested only for a detected terminal after an
explicit user action. These permissions are checked without prompting during
normal notification-to-session navigation.

For monitor-only fallback discovery, the helper reads a bounded prefix of local
Codex and Claude Code JSONL transcript files to obtain session ID, working
directory and parent-session metadata, and uses file modification time for
liveness. Prompt, assistant and tool content is neither placed in events nor
persisted. The fallback does not read terminal output or capture the screen.

The optional Phase 12 relay stores account-subject hashes, public device keys,
routing identifiers, expiry/sequence metadata and ciphertext. Prompt, command,
path, source and decision content remain inside the end-to-end encrypted
payload. APNs tokens are encrypted at rest and APNs receives only an envelope
identifier/category hint. Acknowledged or expired ciphertext has short,
configurable retention; request-body logging is forbidden.

On iOS, private device keys, refresh/access tokens and paired-Mac public-key
bindings are stored in a device-only Keychain access group. Decrypted local
inbox/session state uses complete file protection in the app-group container.
The Notification Service Extension reads keys only to decrypt a single pending
envelope, applies the user's Hidden/Project Only/Full preview setting, and falls
back to a generic notification on every failure. It does not acknowledge the
envelope or persist decrypted agent content. Secret questions are never
answerable from notification actions or the companion app.
