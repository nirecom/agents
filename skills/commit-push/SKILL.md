---
name: commit-push
description: Commit and push changes to the remote repository
model: haiku
effort: low
---

Commit staged/unstaged changes and push to the remote.

## Procedure

1. Stage changes with `git add`
2. Run `git diff --cached --stat` to show what will be committed
3. Draft a commit message and present it in chat.
4. Create the commit with the approved message
5. Push to the current branch (`git push`; if no upstream is set, use `git push -u origin <branch>`)

Each git command (add, commit, push) must be a **separate Bash call** per `rules/git.md`.

## Rules

- Follow all existing commit and push rules
- If push fails, report the error — do not force-push
