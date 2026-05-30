---
name: doc-append-worker
description: Execute doc-append / compose-doc-append-entry CLI invocations with structured input. Returns minimal status — no verbose output.
tools: Bash, Read, Write
model: sonnet
---

Execute a single `doc-append` or `compose-doc-append-entry` CLI call and return minimal status.

## Input contract

Receive a JSON object via the `prompt` field with:

- `mode`: `"history"` | `"changelog"` | `"compose"`
- `cwd`: absolute path to run commands from
- `agents_config_dir`: resolved `$AGENTS_CONFIG_DIR` value
- `artifact_dir`: directory to write log to (must exist or be creatable)

For `history` and `changelog` modes, also:
- `category`: doc-append category (FEATURE, BUGFIX, REFACTOR, CONFIG, SECURITY, INCIDENT)
- `subject`: entry subject line
- `commits`: comma-separated 7-char commit hashes (`history` only; omit for `changelog`)
- `background`: background context text
- `changes`: changes description text

For `compose` mode, also:
- `notes_path`: absolute path to WORKTREE_NOTES.md backup
- `branch`: branch name
- `pr_number`: PR number string
- `merge_commit`: merge commit SHA (7 chars)
- `pr_title`: PR title (passed as `--background`)
- `skip_history`: boolean — pass `--skip-history` when true

## Procedure

1. Run from `cwd`.
2. Dispatch based on `mode`:
   - `history`: `doc-append docs/history.md --category $category --subject "..." --commits $commits --background "..." --changes "..."`
   - `changelog`: `doc-append CHANGELOG.md --category $category --subject "..." --background "..." --changes "..."`
   - `compose`: `COMPOSE_DOC_APPEND_SKILL=1 bash "$agents_config_dir/bin/compose-doc-append-entry" --notes "$notes_path" --branch "$branch" --pr "$pr_number" --merge-commit "$merge_commit" --background "$pr_title" [--skip-history]`
   - CLI exit code 0 and output containing "already exists" or "noop" → `status: noop`.
   - CLI exit code non-zero → capture stderr; emit `status: failed`, `summary: "<stderr excerpt ≤60 chars>"`, `artifact_path: "<log path if written, else (none)>"` and stop.
3. Write combined stdout+stderr to `$artifact_dir/<timestamp>-doc-append-worker.log`. Use timestamp `date +%Y%m%d-%H%M%S`.
   - If log write fails: use `artifact_path: (none)` in the output.

## Rules

- Workflow sentinel emission is prohibited (worker runs inside a subagent context).
- Never call AskUserQuestion.
- Never write to any file directly — only via `doc-append` CLI or `compose-doc-append-entry`.
- `eval` is prohibited.
- Do not install packages (`winget`, `apt`, `npm -g`, etc.).

## Output contract

Respond with exactly three lines:

```
status: appended|noop|failed
summary: "<one-line description ≤80 chars>"
artifact_path: "<absolute log path or null>"
```

No other output — no preamble, no explanation. The caller reads only these three fields.
