---
name: pm-remove
description: Remove issues from the assigned list of this PM session — the issue-title hook records the change with the reason, and an empty list ends the PM session; this skill reports it. Usage — /pm-remove #A … [reason]
user-invocable: true
---

The UserPromptSubmit hook is the only writer of the PM state; this skill never writes it.

## Procedure

Follow the assignment rules in `skills/_shared/pm-supervisor-duties.md` `## PM session`.

### PMR-1 — Read the hook result

Read the `[pm-session] op=remove tag=<tag>` context the hook added to this prompt; its `issues=` line is the updated assigned list and `ended=` tells whether the PM session ended.
When the hook refused the prompt (not a PM session, an ended one, an older generation, or an issue not assigned), this skill does not run; the user sees the refusal reason.
When no `[pm-session]` context is present, tell the user nothing was removed and stop.

### PMR-2 — Report

Report the PM tag and the updated assigned list to the user in CONV_LANG.
With `reason=unstated`, run `node "$AGENTS_MAIN_ROOT/bin/pm-state" set-reason --text "<reason>"` once only when the user's last message states the reason plainly; never guess one.
When `ended=true`, state explicitly that this PM session has ended, that its PM tag is used and can never be reused, and that new work starts in a new session.

### PMR-3 — Issue sequence table (`ended=false` only)

The hook drops the removed issues from the issue sequence table in the same write, and marks a row whose `blocked_by` named one of them unverified (`removed`).
Check the table with `node "$AGENTS_MAIN_ROOT/bin/pm-state" show --session "$CLAUDE_CODE_SESSION_ID"`, re-check any unverified row per `skills/pm-init/SKILL.md` PMI-4, and present the result to the user.
