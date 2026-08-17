---
name: supervisor-report
description: Record an EM Supervisor observation (trouble sign, incident, or neutral note) for the current session.
user-invocable: false
---

Invoked by Claude Code itself when a trigger in `rules/supervisor-reporting.md` fires — never by a human, which is why `user-invocable` is false.

## Procedure

SR-1. Resolve `$SID`: read the `Session-ID:` field of the worktree's `WORKTREE_NOTES.md`. Only if that file or field is absent, fall back to `$CLAUDE_SESSION_ID` — Anthropic bug #27987 makes its propagation into Bash unreliable, so it is the fallback, not the source. If neither resolves, still report: state in your turn output what you observed and that no session id could be resolved.

SR-2. Choose `categories` (comma-separated, multi-select), `severity`, `detail` (what was observed, free text), and `reporter` (the skill or agent name) from the tables below.

SR-3. Run, as one Bash call: `node "$AGENTS_CONFIG_DIR/bin/supervisor-report" --categories <cats> --severity <sev> --detail "<text>" --reporter "<name>" --session-id "$SID"`. All four flags are mandatory — the CLI aborts when one is missing.
   `<text>` is observation text that may come from tool output or a file, so treat it as untrusted: before substituting it, strip every `` ` ``, `$`, `\`, `"`, newline and control character from it, and collapse the remainder to a single line — a `$(...)` or backtick left in the detail executes inside the double-quoted argument.
   Text you cannot safely reduce that way must not be interpolated at all: shorten the detail to your own one-line summary and leave the raw text out.

SR-4. Never swallow a non-zero exit. Put the fact that the report failed, plus the CLI's stderr, in your turn output: a lost observation is the worst failure mode of this skill.

## Categories

| Category | When to use |
|---|---|
| `intent` | Scope or non-goal misalignment with intent.md |
| `outline` | Approach selection or delivery plan issue |
| `detail` | File-level implementation plan inconsistency |
| `workflow` | Workflow rule violation, step skip, sentinel issue |
| `code` | Code writing issue (logic error, naming, structure) |
| `test` | Test failure, flaky test, coverage gap |
| `security` | Credential leak risk, dangerous input handling |
| `performance` | Build/runtime slowdown, resource spike |
| `env` | Missing env var, dependency version mismatch |
| `other` | Does not fit any category above |

## Severity

| Severity | When to use |
|---|---|
| `error` | Confirmed failure or clear violation |
| `warning` | Suspicious behaviour, likely issue |
| `notice` | Worth recording, not immediately concerning |

Example: `--categories intent,code --severity warning --detail "changes touch declared non-goal: async LLM calls" --reporter "write-code"`
