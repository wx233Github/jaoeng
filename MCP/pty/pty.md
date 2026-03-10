# PTY-runner usage policy (opencode MCP)

When a task requires running commands or interacting with terminal UI, always use the MCP server `one-mcp` rather than guessing outputs.

## When to use one-mcp
Use `one-mcp` for any of the following:
- Interactive CLI menus / prompts (e.g. "choice", "请输入选项", "Press Enter", yes/no prompts)
- Programs that require a TTY (full-screen UI, curses, installers, scripts that behave differently without a terminal)
- Anything where you need to show real command output to the user

## How to use (required workflow)
1. Start a session with `pty_spawn`.
2. Read output with `pty_read` (or `pty_read_until` if available).
3. Only send inputs using `pty_write` (include `\n` for Enter).
4. Continue reading and present the output verbatim to the user.
5. Close the session with `pty_close` when done.

## Output handling rules
- Do NOT fabricate terminal output. Only quote what was returned by `pty_read`.
- If output is incomplete, keep calling `pty_read` with a short `timeout_ms` (e.g. 300–800ms) until stable.

## Sudo rules
- Never ask for or type a sudo password.
- Prefer `sudo -n <command>` so it fails fast if passwordless sudo is not configured.
- If sudo prompts for a password or fails, stop and ask the user to handle sudo configuration.

## Safety/confirmation
- If a step could change system state (install/remove packages, modify configs), ask the user for confirmation before proceeding to the next irreversible action.
