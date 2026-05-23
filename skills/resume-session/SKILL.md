---
name: resume-session
description: Detect a mid-workflow interruption and resume the right skill (workflow state in_progress step or pending worktree-end cleanup). Interactive sessions only.
model: sonnet
user-invocable: true
---

IMPORTANT: Interactive session required. Hard-fail in non-interactive contexts (claude -p, /loop, subagents). Step 1 performs this check before any detection runs.

## Purpose

Detects a `workflow-state` `in_progress` step or a `worktree-end` cleanup marker, then dispatches to the matching skill. Session id is read via `CLAUDE_ENV_FILE` — never `CLAUDE_SESSION_ID` directly.

## Procedure

### Step 1 — Hard-fail check

Call AskUserQuestion: "Confirm: resume interrupted workflow session?" with options `Resume` / `Cancel`.
- If AskUserQuestion is unavailable (non-interactive context), abort immediately: output `Error: /resume-session requires an interactive session.` and stop.
- If user picks `Cancel`, stop.

### Step 2 — Detect

Run via Bash:
```
node "$AGENTS_CONFIG_DIR/bin/resume-session-detect"
```
Parse stdout as JSON. Dispatch by `type` in Step 3.

### Step 3 — Dispatch by type

| type | Action |
|---|---|
| `none` | Output "No interrupted workflow detected." and stop. |
| `skill` | AskUserQuestion "Workflow paused at `<step>`. Re-run `/<skill>`?" (`Resume` / `Cancel`). On Resume: invoke `<skill>` skill. |
| `sentinel-wait` (step ≠ `user_verification`) | Display `hint`. AskUserQuestion: `Acknowledged (I'll handle manually)` / `Cancel`. No auto-emit, no auto-skip. |
| `sentinel-wait` (step = `user_verification`) | Display: "user_verification pending. Emit `<<WORKFLOW_USER_VERIFIED: <reason>>>` manually when ready." AskUserQuestion: `Acknowledged` / `Cancel`. Never auto-emit or auto-advance. |

### Step 4 — Completion

This skill is an out-of-band utility — emit no workflow step sentinels.

## Rules

- Read workflow state only; never write it.
- Re-invoked skill idempotency is the called skill's responsibility.
- `/boost` is removed (PR #468).
