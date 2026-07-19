# yusufiwt Navigation

The extension keeps an in-memory mapping from a yusufiwt correlation token
to the active VS Code/Cursor terminal. The native app calls the extension URI
handler with that token. If the terminal no longer exists, the extension opens
the captured workspace and reports the degraded result instead of guessing.

Registration is explicit through `yusufiwt: Register Active Terminal` or
the `agentcontrol.registerTerminal` command. No terminal output is read.
