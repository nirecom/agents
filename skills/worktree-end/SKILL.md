---
name: worktree-end
description: Inventory gitignored state, merge PR, and clean up a git worktree after task completion
---

Inventory and preserve gitignored state, merge the PR, then remove the worktree safely.

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
   Run all three commands (NUL-delimited, handles spaces and non-ASCII paths):
   ```
   git -C <worktree> ls-files --others --ignored --exclude-standard -z
   git -C <worktree> ls-files --others --exclude-standard -z
   git -C <worktree> status --porcelain=v1 -z
   ```
   Also read `WORKTREE_NOTES.md` if it exists (created by `/worktree-start`).

   **Generate backup manifest** — for each gitignored file: path, size, mtime, sha256.
   Do NOT include secret values in the manifest — metadata only.

   **Docker bind mount impact detection** (both running and stopped containers):
   ```
   docker ps -a --format json
   ```
   Check whether any `.Mounts.Source` or `env_file` entry references the worktree path.
   Normalize across path formats (WSL `/mnt/<drive>/`, Windows `<DRIVE>:\`, MSYS `/drive/`)
   before comparing. Report stopped containers too: "Stopped containers included."

   **Present DRY RUN summary to the user:**
   - Paths to be deleted / untracked count / ignored count
   - Preservation candidates (from inventory + WORKTREE_NOTES.md)
   - Docker mount impact (if any)
   - Proposed backup destination:
     - **Default:** `<main_root>/.worktree-backup/<branch>/` (gitignored via `.git/info/exclude`)
     - Alternatives: main checkout at same relative path, user-specified directory, discard
   - Commands that will be executed

   After user approval: copy preservation targets to the chosen destination.
   If Docker containers reference the worktree path, stop them and restart from the main path.
   Never delete gitignored state silently — always present the inventory first.

7. **Cleanup** (only after confirmed merge success and inventory — never before):
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

8. **Final report:** PR URL, merge state, backup manifest location, branches deleted, worktree path removed.

## Rules

- **wait / abort paths: no destructive steps.** Only merge-success path runs cleanup.
- `git worktree remove --force` is prohibited unless the user gives explicit re-approval
  after reviewing the `rules/ops.md` decision path.
- `git branch -D` (force-delete) is prohibited — use `-d` only.
- Do not run cleanup if merge step failed or was skipped.
- Always propose `.worktree-backup/<branch>/` as the default backup destination; never silently pick a different path.
- Always check stopped containers, not just running ones, for bind mount conflicts.
- Secret values must not appear in the backup manifest.
- `gh --version` must succeed before any gh command — surface installation guidance if not.
