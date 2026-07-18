# Adapter compatibility

Published: 2026-07-18. Machine-readable source:
`Config/Operations/adapter-compatibility.json`.

| Provider | Policy range | Mode | Capabilities | Unknown version |
|---|---|---|---|---|
| Codex | 0.x, 1.x | Managed/hook | Monitor, approve, deny | Monitor-only |
| Claude Code | 1.x, 2.x | Hook | Monitor, approve, deny, non-secret answers | Monitor-only |
| Gemini CLI | 0.x, 1.x | Hook | Monitor, approve, deny | Monitor-only |

These major ranges are covered by normalized fixtures and contract tests. A new
major is never assumed compatible: decision controls are hidden until a fixture
and matrix update ship. Generic hooks are always monitor-only.

Local-only macOS use requires no AgentControl account. Sign-in is only for the
optional iPhone/watch relay companion.
