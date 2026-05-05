---
name: commit-push
description: Commit and push changes to the remote repository
---

Commit staged/unstaged changes and push to the remote.

## Pre-commit check

If tests are missing or the commit hook blocks due to missing tests:
- Never write tests directly in this conversation.
- Invoke the `/write-tests` skill first, then resume commit-push.

If documentation is missing or the commit hook blocks due to missing documentation updates:
- Invoke the `/update-docs` skill first, then resume commit-push.

## Procedure

1. Stage changes with `git add`
2. Run `git diff --cached --stat` to show what will be committed
3. Create the commit with the drafted message
5. Push to the current branch (`git push`; if no upstream is set, use `git push -u origin <branch>`)

Each git command (add, commit, push) must be a **separate Bash call** per `rules/git.md`.

`settings.json` `model` and `effort` fields are auto-updated by the system — exclude them from the commit if they appear in the diff.

### Push retry on non-fast-forward

If `git push` fails with "non-fast-forward" or "fetch first", retry up to 3 times.
Each command is a **separate Bash call** (rules/git.md — do NOT chain with `&&`):

1. `git fetch origin <branch>`
2. `git pull --rebase --autostash origin <branch>`
   — Stop if rebase reports conflicts; surface to user.
3. `git push origin <branch>`

Sleep between attempts: 2s before attempt 2, 5s before attempt 3.
After 3 failures, report to user — do NOT force-push, do NOT use `--no-verify`.

## Rules

- Follow all existing commit and push rules
- If push fails, report the error — do not force-push
