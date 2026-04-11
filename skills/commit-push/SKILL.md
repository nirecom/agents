---
name: commit-push
description: Commit and push changes to the remote repository
model: haiku
effort: low
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

## Rules

- Follow all existing commit and push rules
- If push fails, report the error — do not force-push
