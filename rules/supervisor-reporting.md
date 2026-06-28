# EM Supervisor Reporting

## When to Report

Report when you observe any of the following during skill or agent execution:

- Trouble signs: something looks off but no failure yet — "I'm not sure this is right" counts
- Incidents: a confirmed failure, violation, or unexpected outcome
- Neutral observations worth recording for cross-session pattern detection
- When in doubt: `WORKFLOW_OFF`/`WORKTREE_OFF` sentinel used; hook blocked a sanctioned command and required a workaround; fallback path taken instead of primary; step needed a retry or manual intervention — all warrant a report.

## How to Report

Run `node "$AGENTS_CONFIG_DIR/bin/supervisor-report" --categories <cats> --severity <sev> --detail "<text>" --reporter "<name>" --session-id "$SID"`.

Resolve `$SID` from `WORKTREE_NOTES.md` (field `Session-ID:`) before calling. Do not rely on `$CLAUDE_SESSION_ID` propagation (Anthropic bug #27987).

## Fields

| Field | Values | Description |
|---|---|---|
| `categories` | comma-separated (multi-select) | What kind of observation |
| `severity` | `error` / `warning` / `notice` | How concerning |
| `detail` | free text | What was observed |
| `reporter` | skill or agent name | Who is reporting |
| `session-id` | alphanumeric + `-` / `_` | Current session identifier |

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

## Example

Example: `--categories intent,code --severity warning --detail "changes touch declared non-goal: async LLM calls" --reporter "write-code"`
