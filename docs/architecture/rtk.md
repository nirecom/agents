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

## bin/rtk-cmd adoption convention

`bin/rtk-cmd` is a lightweight wrapper used **only for scripts that intentionally
emit raw human-readable output to Claude** — commands whose output RTK natively
compresses (`git`, `gh`, `grep`, `docker`, etc.).

### When to use

The script's design is to stream raw text output (e.g. `git log`, `gh issue list`)
directly to Claude's stdout. Examples:

    bin/rtk-cmd git log --oneline -20   # compress raw git log output before Claude reads it
    bin/rtk-cmd gh issue list           # compress raw issue list output before Claude reads it

### When NOT to use (all current 195 bin/ scripts fall into these categories)

- Machine-readable flag calls (`--json`, `--format=`, `--numstat`, etc.) — RTK passes them through unchanged, so wrapping has no effect.
- Calls whose output is captured into a variable and reformatted by node/jq/awk — RTK cannot compress node's output.
- `grep`/`find`/`cat` used only for internal control flow or evaluation — output never reaches Claude.

The #2370 cross-cutting survey (all RTK-eligible commands × 195 bin/ scripts) confirmed
these as structural invariants. Adopt when a use case arises.

## enforce-worktree validation of rtk-wrapped git commands

`hooks/enforce-worktree.js` (via `hooks/lib/bash-write-patterns/segment-utils.js`)
registers an `rtk` entry in `WRAPPER_SPECS`. Without this entry, `detectWritePredicate`
returned `null` for any `rtk git …` command, causing `handleBashWrite` to exit
fail-open (ALLOW from the main worktree).

The entry declares three verb tiers that `peelWrappers` uses to classify rtk subcommands:

| Field | Values | Meaning |
|---|---|---|
| `passthroughDispatchVerbs` | `proxy`, `err`, `test`, `summary` | rtk dispatches these unchanged to their own executor — treat the next argv token as the real command |
| `shellBodyVerbs` | `run` | body is a shell string; treat it as `sh -c <body>` for write detection |
| `nativeVerbs` | `read`, `json`, `find`, `gain`, `config`, `init`, `env`, `help`, `version` | rtk-native read-only operations; never write to the session repo |

With this entry, `rtk git commit` is correctly peeled to `git commit` and blocked from
the main worktree, while `rtk read …` is recognized as a native verb and allowed.
