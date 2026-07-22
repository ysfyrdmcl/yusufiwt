# Adapter compatibility

Published: 2026-07-19. Machine-readable source:
`Config/Operations/adapter-compatibility.json`.

| Provider | Policy range | Mode | Capabilities | Unknown version |
|---|---|---|---|---|
| Codex | 0.x, 1.x | Managed hook | Monitor, approve, deny, structured `request_user_input` answers | Monitor-only |
| Claude Code | 1.x, 2.x | Managed hook | Monitor, approve, deny, non-secret Elicitation/AskUserQuestion answers, plan review | Monitor-only |
| Gemini CLI | 0.x, 1.x | Managed hook | Monitor, approve, deny, plan review | Monitor-only |
| Cursor | 1.x–3.x | Managed hook + IDE navigation | Monitor, scoped write/delete/task and shell/MCP approve/deny, context usage | Monitor-only |

Codex and Claude Code additionally support hook-free, monitor-only session
discovery from bounded local JSONL transcript metadata. This fallback reports
liveness and parent/subagent relationships only; it exposes no decision or
usage capability and yields authority to structured events.

These major ranges are covered by normalized fixtures and contract tests. A new
major is never assumed compatible: decision controls are hidden until a fixture
and matrix update ship. Generic hooks are always monitor-only. Cursor's current
hook contract does not expose Agent questions or plan review as a stable
synchronous response contract, so those two capabilities are explicitly
unsupported instead of inferred from UI text.

Official contracts used for the matrix: [Codex hooks](https://learn.chatgpt.com/docs/hooks),
[Claude Code hooks](https://code.claude.com/docs/en/hooks),
[Gemini CLI hooks](https://geminicli.com/docs/hooks/reference/), and
[Cursor hooks](https://cursor.com/docs/hooks). Cursor `preToolUse` accepts `ask`
in its schema but does not currently enforce it; managed mutable-tool hooks are
therefore fail-closed when yusufiwt cannot return a user decision. Cursor's
specialized shell/MCP hooks retain their enforced native `ask` fallback.

Local-only macOS use requires no yusufiwt account. Sign-in is only for the
optional iPhone/watch relay companion.
