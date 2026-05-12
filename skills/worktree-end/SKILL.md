---
name: worktree-end
description: Inventory gitignored state, merge PR, and clean up a git worktree after task completion
---

Inventory and preserve gitignored state, merge the PR, then remove the worktree safely.

## Procedure

1. **Pre-flight checks:**
   - `gh --version` — abort with installation guidance if gh is not found.
   - Verify cwd is inside a linked worktree (not the main worktree):
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

3. **Ask the user:**
   First output the PR URL as a clickable markdown link in the main conversation:
   `PR #<N> is open: [<url>](<url>)`
   Then call `AskUserQuestion`: "PR #<N> — merge, wait, or abort?"
   - **merge**: proceed to step 4.
   - **wait**: display URL and stop — do **not** clean up.
   - **abort**: display URL and close-PR guidance, then stop — do **not** clean up.

   If `AskUserQuestion` is unavailable (e.g. headless `claude -p`), default to **wait**.

4. **Merge** (only on explicit user choice):
   ```
   gh pr merge --squash --delete-branch
   ```
   If merge fails (protected branch policy, CI failure, conflict): surface the error and stop.
   Do **not** force-merge or bypass checks.

5. **Gitignored state inventory** (before removing the worktree):
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
     - Alternatives: main worktree at same relative path, user-specified directory, discard
   - Commands that will be executed

   After user approval: copy preservation targets to the chosen destination.
   If Docker containers reference the worktree path, stop them and restart from the main path.
   Never delete gitignored state silently — always present the inventory first.

6. **Cleanup** (only after confirmed merge success and inventory — never before):
   a. Resolve the main repo root from the worktree's `.git` file.
   b. **Write branch-delete marker** so the `enforce-worktree` hook will permit
      step f below. The marker lives in the SHARED `.git` directory so it is
      readable from both the main worktree and any linked worktree.
      - Resolve `<git-common-dir>` via `git -C <main> rev-parse --git-common-dir`.
        The marker path is `<git-common-dir>/info/pending-branch-delete`.
      - Marker contents (exactly two lines, LF or CRLF both accepted by the hook):
        ```
        <branch>
        <absolute-worktree-path>
        ```
        `<absolute-worktree-path>` must be the path being removed in step c, and
        must resolve under `WORKTREE_BASE_DIR` (the hook re-validates this).
      - Use the Write tool, not heredoc/echo, to keep the file write atomic.
   c. `git -C <main> worktree remove <path>` (never `--force` — see rules).
   d. `git -C <main> worktree prune`
   e. If `<WORKTREE_BASE_DIR>/<task-name>/` directory is now empty, delete it
      (non-recursive to prevent accidents):
      - POSIX: `rmdir "<WORKTREE_BASE_DIR>/<task-name>"`
      - PowerShell: `Remove-Item "<WORKTREE_BASE_DIR>\<task-name>"` (non-recursive)
   f. `git -C <main> branch -D <branch>` — `-D` (force) is required because
      squash-merge produces a new commit not recognised by `-d`'s "fully merged"
      check; the marker written in step b authorises this exact deletion.
   g. **Remove the marker** at `<git-common-dir>/info/pending-branch-delete`
      whether step f succeeded or failed (avoid leaving stale markers).
      - POSIX: `rm "<git-common-dir>/info/pending-branch-delete"`
      - PowerShell: `Remove-Item -LiteralPath "<git-common-dir>\info\pending-branch-delete"`
        (use `-LiteralPath`, not `-Path`, to avoid wildcard expansion)

      The `enforce-worktree` hook permits this via `isAllowedMarkerDelete`:
      target must equal the marker path AND the branch on line 1 must no longer
      exist. Multi-target invocations and fatal git errors fail closed.
      If step f failed the marker is retained — the next `/worktree-end` run
      will overwrite it.
   h. `git -C <main> fetch --prune origin`
      `git -C <main> pull --ff-only`
         (`--ff-only`: diverge 時はサイレントマージせず停止する)
   i. Verify cleanup: `git -C <main> worktree list` — confirm no stale entries.

   **Why this dance:** the `enforce-worktree` hook classifies `git branch -d/-D`
   as a write op and blocks it from any worktree by default. The marker file is
   the only authorised path; only this skill produces it. Direct ad-hoc
   `git branch -D` from any worktree is intentionally rejected — this prevents
   accidental loss of unmerged work and keeps cleanup auditable.

7. **Final report:** PR URL, merge state, backup manifest location, branches deleted, worktree path removed.

## Rules

- **wait / abort paths: no destructive steps.** Only merge-success path runs cleanup.
- `git worktree remove --force` is prohibited unless the user gives explicit re-approval
  after reviewing the `rules/ops.md` decision path.
- Branch deletion uses `git branch -D` only inside step 6f, gated by the
  marker file written in step 6b. Direct ad-hoc `git branch -d/-D` outside this
  skill is rejected by the `enforce-worktree` hook by design.
- Always attempt marker removal (step 6g); the hook retains the marker if
  branch delete (step f) failed.
- Do not run cleanup if merge step failed or was skipped.
- Always propose `.worktree-backup/<branch>/` as the default backup destination; never silently pick a different path.
- Always check stopped containers, not just running ones, for bind mount conflicts.
- Secret values must not appear in the backup manifest.
- `gh --version` must succeed before any gh command — surface installation guidance if not.
