---
name: pm-add
description: Add issues to the assigned list of this PM session — the issue-title hook records them with the reason; this skill reports the updated list. Usage — /pm-add #A … [reason]
user-invocable: true
---

The UserPromptSubmit hook is the only writer of the PM state; this skill never writes it.

## Procedure

Follow the assignment rules in `skills/_shared/pm-supervisor-duties.md` `## PM session`.

### PMA-1 — Read the hook result

Read the `[pm-session] op=add tag=<tag>` context the hook added to this prompt; its `issues=` line is the updated assigned list.
When the hook refused the prompt (not a PM session, an ended one, an older generation, or an issue another PM owns), this skill does not run; the user sees the refusal reason.
When the refusal is an overlap or an issue whose scope cannot be checked, report the other PM's tag, or the reason and its exit, to the user.
When the refusal names a PM set on an ancestor or a descendant of the issue (the PM field), report that PM's tag and session to the user; that PM removes it first.
When no `[pm-session]` context is present, tell the user nothing was added and stop.

### PMA-2 — Report

Report the PM tag and the updated assigned list to the user in CONV_LANG.
With `reason=unstated`, run `node "$AGENTS_MAIN_ROOT/bin/pm-state" set-reason --text "<reason>"` once only when the user's last message states the reason plainly; never guess one.

### PMA-3 — Issue sequence table

Place the added issues in the issue sequence table per `skills/pm-init/SKILL.md` PMI-4, and present the result to the user.
