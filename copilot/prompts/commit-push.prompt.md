---
name: commit-push
description: Stage, commit with a conventional message, and push the current branch.
---

Stage relevant changes, write a conventional commit message, then push.

## Pre-commit checks

If tests are missing or the commit hook blocks due to missing tests, run `/write-tests` first.
If documentation is missing, run `/update-docs` first.

## Steps

1. Run `git status` to confirm what will be staged.
2. Stage files explicitly by name — do NOT use `git add -A` or `git add .`.
3. Show `git diff --cached --stat`.
4. Write a commit message: `<type>(<scope>): <subject>` (max 72 chars, body optional).
   Omit attribution trailers from the commit message.
5. Commit.
6. Push (`git push`; if no upstream, use `git push -u origin <branch>`).
7. Report the commit hash and pushed branch.

Each git command (add, commit, push) must be a separate terminal call per `rules/git.md`.
If push fails, report the error — do not force-push.
