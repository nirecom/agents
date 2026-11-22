---
name: pm-rename
description: Rename the PM tag of this PM session — the issue-title hook rewrites the PM field of every assigned issue, retires the old tag and moves its mailbox; this skill reports the result. Usage — /pm-rename <new tag>
user-invocable: true
---

The UserPromptSubmit hook is the only writer of the PM state and the PM field; this skill never writes either.

## Procedure

### PMN-1 — Read the hook result

Read the `[pm-session] op=rename tag=<new tag>` context the hook added to this prompt; its `renamed_from=` line is the old tag.
When the hook refused the prompt (not a PM session, an ended one, an older generation, a used tag, or an unfinished rename to another tag), this skill does not run; the user sees the refusal reason.
When no `[pm-session]` context is present, tell the user nothing was renamed and stop.

### PMN-2 — Report

Report the old and the new PM tag to the user in CONV_LANG.
State that the old tag is retired and can never be reused, and that the session name is unchanged until the user renames it.

## Rules

- A refusal midway (a PM field write failed) keeps the rename unfinished; the user retypes the same `/pm-rename <new tag>` to finish it, and owner lookups resolve both tags to this PM meanwhile.
