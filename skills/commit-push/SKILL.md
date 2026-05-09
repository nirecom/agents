---
name: commit-push
description: Commit and push changes, then create or reuse a PR with optional merge
---

Commit staged/unstaged changes, push to the remote, and open or reuse a PR.

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
4. Push to the current branch:
   - If no upstream is set: `git push -u origin <branch>`
   - Otherwise: `git push`

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

### PR step (after push)

5. **Skip if `ENFORCE_WORKTREE=off`** — direct-main work does not use PRs.

6. **PR resolution (idempotent):**
   ```
   gh pr view --json state,url
   ```
   - `state == OPEN` → reuse the existing PR URL (do NOT create a duplicate).
   - No PR or closed → `gh pr create --fill`.
   Display the PR URL.

7. First output the PR URL as a clickable markdown link in the main conversation:
   `PR #<N> is open: [<url>](<url>)`
   Then ask via `AskUserQuestion`: "PR #<N> — merge, wait, or abort?"
   - **merge**: `gh pr merge --squash --delete-branch`
     Then: `git fetch --prune origin`
     Note: if working from a worktree, run `/worktree-end` afterward for full cleanup.
   - **wait**: display URL and stop.
   - **abort**: display URL and stop.

   If `AskUserQuestion` is unavailable (e.g. headless `claude -p`), default to **wait**.

## Rules

- Follow all existing commit and push rules.
- If push fails, report the error — do not force-push.
- Merge is always user-confirmed — never auto-merge without `AskUserQuestion`.
- Note: `git branch -D` (force-delete) and `--no-verify` are prohibited.
