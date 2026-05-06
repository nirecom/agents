---
name: worktree-end
description: Merge PR and clean up a git worktree after task completion
---

Push the branch, create or reuse a PR, optionally merge, then remove the worktree and
associated directories.

## Procedure

1. **Pre-flight checks:**
   - `gh --version` — abort with installation guidance if gh is not found.
   - Verify cwd is inside a linked worktree (not the main checkout):
     `git rev-parse --git-common-dir` must differ from `git rev-parse --git-dir`.
     If they are equal, abort: the user must `cd` into the worktree first.

2. **PR resolution (idempotent):**
   Push the current branch if not already pushed (`git push -u origin <branch>`).
   Then check for an existing open PR:
   ```
   gh pr view --json state,url
   ```
   - `state == OPEN` → reuse the existing PR URL (do NOT create a duplicate).
   - No PR or closed → `gh pr create --fill`.
   Display the PR URL.

3. **AUTO_MERGE_PR check:**
   - `AUTO_MERGE_PR=off`: display the PR URL and stop — do **not** merge or clean up.
   - `AUTO_MERGE_PR=on` (default): proceed to ask the user.

4. **Ask the user** (when AUTO_MERGE_PR=on):
   `AskUserQuestion`: "PR is open at <url>. Choose: [merge / wait / abort]"
   - **merge**: proceed to step 5.
   - **wait**: display URL and stop — do **not** clean up.
   - **abort**: display URL and close-PR guidance, then stop — do **not** clean up.

5. **Merge** (only on explicit user choice):
   ```
   gh pr merge --squash --delete-branch
   ```
   If merge fails (protected branch policy, CI failure, conflict): surface the error and stop.
   Do **not** force-merge or bypass checks.

6. **Gitignored state inventory** (before removing the worktree):
   Read `WORKTREE_NOTES.md` in the worktree root (created by `/worktree-start`).
   - List any gitignored files that were copied into the worktree.
   - If the worktree contains gitignored files **not** recorded in `WORKTREE_NOTES.md`
     (created during the task), enumerate them and present the list to the user:
     ```
     git -C <wt> ls-files --others --ignored --exclude-standard
     ```
   - Ask the user: "These gitignored files will be deleted with the worktree. Copy any back to main? [list / skip]"
     - **list**: user specifies which to copy; copy them to the main checkout before removal.
     - **skip**: proceed without copying.
   - Never delete gitignored state silently — always present the inventory first.

7. **Cleanup** (only after confirmed merge success — never before):
   a. Resolve the main repo root from the worktree's `.git` file.
   b. `git -C <main> worktree remove <path>` (never `--force` — see rules).
   c. `git -C <main> worktree prune`
   d. If `<WORKTREE_BASE_DIR>/<task-name>/` directory is now empty, delete it
      (non-recursive to prevent accidents):
      - POSIX: `rmdir "<WORKTREE_BASE_DIR>/<task-name>"`
      - PowerShell: `Remove-Item "<WORKTREE_BASE_DIR>\<task-name>"` (non-recursive)
   e. `git -C <main> branch -d <branch>` (soft delete only — `-D` is prohibited).
   f. `git -C <main> fetch --prune origin`
   g. Verify cleanup: `git -C <main> worktree list` — confirm no stale entries.

7. **Final report:** PR URL, merge state, branches deleted, worktree path removed.

## Rules

- **wait / abort paths: no destructive steps.** Only merge-success path runs cleanup.
- `git worktree remove --force` is prohibited unless the user gives explicit re-approval
  after reviewing the `rules/ops.md` decision path.
- `git branch -D` (force-delete) is prohibited — use `-d` only.
- Do not run cleanup if merge step failed or was skipped.
- `gh --version` must succeed before any gh command — surface installation guidance if not.
