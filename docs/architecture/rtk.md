# RTK Integration

[RTK](https://github.com/rtk-ai/rtk) is a third-party CLI that compresses Bash
command output to reduce LLM input token usage. This repository hooks into it;
it is never a required dependency.

## Enabling

Set `RTK=on` in `.env`. RTK must already be installed (`rtk` on `PATH` or at a
known location — see `RTK_BIN` in `.env.example`).

## How the hook works

`hooks/rtk-rewrite.js` intercepts each Bash `PreToolUse` event and, when RTK is
enabled, delegates eligible commands to `rtk hook claude` so RTK's output
compression and native audit both apply.

Agents repo internal commands are always excluded: any command headed by a
`bin/` script or referencing `$AGENTS_CONFIG_DIR` bypasses RTK wrapping
unconditionally (`isAgentsEmit` guard). This ensures workflow-critical plumbing
runs at full fidelity regardless of RTK being on or off.

## Audit

Set `RTK_AUDIT=on` in `.env` to record a JSONL line each time the hook's own
guards reject a command. The log is written to
`~/.agents/logs/rtk-guard-audit.log` and is independent of RTK's native audit.
