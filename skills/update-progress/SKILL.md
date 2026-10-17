---
name: update-progress
description: Rewrite this session's session-progress.md now (the Current state section plus any unrecorded facts) and show its path. Use before a hand-over or when the user asks.
user-invocable: true
---

The user-forced form of the `[progress check]` request; `rules/progress-update.md` owns what to write.

## Procedure

### UP-1 — Ensure the file

Run `node "$AGENTS_MAIN_ROOT"/bin/progress-file ensure --session $CLAUDE_CODE_SESSION_ID --reason update-progress` and take the path it prints.

Exit 2 means the session id is missing or invalid: report that one line to the user and stop.

### UP-2 — Update

Read the file, then rewrite the `Current state` section per `rules/progress-update.md`.

Add the facts of the four kinds not yet recorded; when there is nothing new, leave them as they are.

Write with the Edit tool only.

### UP-3 — Report

Show the user the updated path in one line, and nothing else.

## Rules

- The main conversation does this itself; do not delegate it to a subagent.
- Emit no workflow step sentinels: this is an out-of-band utility.
