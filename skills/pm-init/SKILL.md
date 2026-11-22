---
name: pm-init
description: Start a PM session under a PM tag — the issue-title hook records the PM tag, the assigned issue list and the theme; this skill reports the result and opens the consultation or the issue sequence table. Usage — /pm-init <tag> [#A …] [theme]
user-invocable: true
---

A PM session oversees workflow sessions issue by issue and implements nothing itself.
The UserPromptSubmit hook is the only writer of the PM state; this skill never writes it.

## Procedure

### PMI-1 — Read the hook result

Read the `[pm-session] op=init tag=<tag>` context the hook added to this prompt; its `issues=` line is the assigned list.
When the hook refused the prompt, this skill does not run; the user sees the refusal reason.
When the refusal is an overlap or an issue whose scope cannot be checked, report the other PM's tag, or the reason and its exit, to the user.
When no `[pm-session]` context is present, tell the user the PM session was not started and stop.

### PMI-2 — Report

Report the PM tag and the assigned list to the user in CONV_LANG.
When the context carries a PM field drift count or an unread mailbox count, report both counts to the user.
Run `node "$AGENTS_MAIN_ROOT/bin/pm-instructions" --timing session-start` and follow non-empty stdout; on a non-zero exit show its stderr line to the user.
With `reason=unstated`, run `node "$AGENTS_MAIN_ROOT/bin/pm-state" set-reason --text "<reason>"` once only when the user's last message states the reason plainly; never guess one.
The hook names the session; never copy a ListAgents ref into a title.
Only when the hook's name does not show on screen, ask the user to `/rename` the session with the output of `node "$AGENTS_MAIN_ROOT/bin/session-name" --kind pm`.

### PMI-3 — Decide the issues (empty list only)

When `issues=(none)`, consult the user on the theme to decide the issues; the PM session continues with an empty list until then.
The user adds the decided issues with `/pm-add #N …`; never type it on the user's behalf.

### PMI-4 — Issue sequence table

Build the issue sequence table for the assigned scope: one table per group of issues whose start order constrains each other, waves in order, each wave the issues that can start together, each issue with its reason, `blocked_by` and same-file `conflicts`.
Change the order on your own judgment and present it to the user; when the user asks for another order, check its feasibility, apply it when feasible, and give the reason when not.
Write the table only with `node "$AGENTS_MAIN_ROOT/bin/pm-state" set-sequence --session "$CLAUDE_CODE_SESSION_ID" --file <json>`; the payload shape is in `bin/lib/pm-state/sequence.js`.
A refusal that names `gh auth status` means the scope could not be checked: report it and retry after the user fixes the forge access.

## Rules

- A meta issue in the assigned list covers every sub-issue below it, at any depth; never list them one by one.
- Migrate a PM run by hand by having the user type `/pm-init <tag> #A …` in that session, e.g. `/pm-init PM-infra #2728 #708`.
- Change the assigned list only through the user's `/pm-add` and `/pm-remove`.
- A PM session runs no workflow and has no session-close; next-step answers `ACTION=paused REASON=pm-session`.
