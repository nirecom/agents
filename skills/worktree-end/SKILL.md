---
name: worktree-end
description: Inventory gitignored state, merge PR, and clean up a git worktree after task completion
user-invocable: false
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

   Capture: `PR_NUMBER=$(gh pr view --json number --jq .number)`
   Abort if empty — skill cannot proceed without a resolved PR.

3. **Merge decision:**

   Output `PR #<N> is open: [<url>](<url>)`

   Check `AUTO_MERGE_PR` (default `on`):
   `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off AUTO_MERGE_PR on && echo OFF || echo ON'`

   - **`on`**: Announce `AUTO_MERGE_PR=on → merging now.` → step 4.
   - **`off`**: `AskUserQuestion`: "PR #<N> — merge, wait-for-web-merge, or abort?"
     - **merge** → step 4.
     - **wait-for-web-merge** → step 3a.
     - **abort** → stop; no cleanup; no sentinel.

   If `AskUserQuestion` unavailable, default to **wait-for-web-merge**.

3a. **Web-merge wait:**

   Display `PR #<N>: merge via GitHub UI, then reply here.` and the PR URL. Stop.
   On user reply: `gh pr view "$PR_NUMBER" --json state`
   - `MERGED` → step 3b.
   - `OPEN` / `CLOSED` / error → re-display and stop again.

   `$PR_NUMBER` is session-local; `/clear` or new session requires re-invoking `/worktree-end`.

3b. **Post-web-merge sync:**

   `git fetch --prune origin`
   `echo "<<WORKFLOW_USER_VERIFIED>>"` (description: `"User confirmed PR #<N> merged via web UI"`)
   → step 5. Skip step 4.

4. **Local merge:**

   Emit `echo "<<WORKFLOW_USER_VERIFIED>>"` (description: `"PR #<N> — approving merge to main"`),
   then:
   ```
   gh pr merge --squash --delete-branch
   ```
   If merge fails: surface error and stop. Do **not** force-merge or bypass checks.

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
   b. **Write branch-delete marker** (authorises step f via the `enforce-worktree` hook):
      - `<repo-id>` = first 16 hex chars of sha256 of `git -C <main> rev-parse --git-common-dir` (absolute path).
      - `<encoded-branch>` = `encodeURIComponent(<branch>)` (e.g. `feature/foo` → `feature%2Ffoo`).
      - `<plans>` = `$WORKFLOW_PLANS_DIR` if set, else `~/.workflow-plans`.
      - `<marker-path>` = `<plans>/worktree-end/pending-branch-delete-<repo-id>--<encoded-branch>`. Store for step g.
      - Content (two lines): `<branch>` / `<absolute-worktree-path>` (must resolve under `WORKTREE_BASE_DIR`).
      - Use the Write tool (atomic; auto-creates `worktree-end/` on first use).
   b.5. **Switch the session CWD to the main worktree** before removing the
      linked worktree. Run, as its own Bash tool call:
      ```
      cd "<main-worktree-root>"
      ```
      Quote the path (`<main-worktree-root>` may contain spaces, common on
      Windows: `C:\Users\Some Name\...`). Use `cd`, not `git -C`: only `cd`
      updates the Bash tool's persistent CWD. This:
      - Releases the OS-level CWD lock on Windows so step 6c's
        `git worktree remove` does not fail with EPERM (issue #251).
      - Leaves a healthy CWD for subsequent hook invocations after step 6c
        completes: without this step, `process.cwd()` in subsequent hook
        processes still points at the deleted linked-worktree path,
        breaking `enforce-worktree.js` for the rest of the session
        (issue #268). `enforce-issue-close.js` is unaffected (it does not
        call `process.cwd()`).
      Note: step 6c stays as is (`git -C <main> worktree remove <path>`).
      The combined form `cd "<main>" && git -C "<main>" worktree remove "<path>"`
      is also permitted (issue #294) via `isAllowedCdWorktreeRemove` — useful
      on Windows / VS Code where the Bash tool's CWD resets between calls.
      Constraints: no `--force`/`-f`, no further chaining, cd target = main worktree,
      any `-C <path>` must also resolve to the main worktree.
   c. `git -C <main> worktree remove <path>` (never `--force` — see rules).
   d. `git -C <main> worktree prune`
   e. If `<WORKTREE_BASE_DIR>/<task-name>/` is now empty:
      ```
      node "$AGENTS_CONFIG_DIR/hooks/cleanup-orphan-dir.js" "<WORKTREE_BASE_DIR>/<task-name>"
      ```
      (Refuses non-empty dirs, paths outside `WORKTREE_BASE_DIR`, registered worktrees, and symlinks.)
   f. `git -C <main> branch -D <branch>` — `-D` (force) is required because
      squash-merge produces a new commit not recognised by `-d`'s "fully merged"
      check; the marker written in step b authorises this exact deletion.
   g. **Remove the marker** at `<marker-path>` (reuse step b's value verbatim — do **not** recompute)
      whether step f succeeded or failed (avoid stale markers).
      - POSIX: `rm "<marker-path>"`
      - PowerShell: `Remove-Item -LiteralPath "<marker-path>"`
   h. `git -C <main> fetch --prune origin`
      `git -C <main> pull --ff-only`
   i. Verify cleanup: `git -C <main> worktree list` — confirm no stale entries.

7. **Final report:** PR URL, merge state, backup manifest location, branches deleted, worktree path removed.

## Rules

- **wait / abort paths: no destructive steps.** Only merge-success path runs cleanup.
- `git worktree remove --force` is prohibited (see `rules/ops.md` decision path).
- Branch deletion (`git branch -D`) only in step 6f, gated by the marker from step 6b.
- Always attempt marker removal (step 6g) — whether or not step 6f succeeded.
- Do not run cleanup if merge step failed or was skipped.
- Always propose `.worktree-backup/<branch>/` as the default backup destination.
- Always check stopped containers, not just running ones, for bind mount conflicts.
- Secret values must not appear in the backup manifest.
- Use `hooks/cleanup-orphan-dir.js` for orphan directory cleanup (6e) — never `rm -rf`/`Remove-Item -Recurse -Force`.
- `gh --version` must succeed before any gh command.
- `<<WORKFLOW_USER_VERIFIED>>` is emitted in step 4 (before `gh pr merge`) or step 3b
  (after `state == MERGED`). Never on abort or while polling.
- `AUTO_MERGE_PR=on` skips `AskUserQuestion` in step 3 (worktree mode only).
- `$PR_NUMBER` captured in step 2; used explicitly in step 3a. Session-local only.
- This skill does NOT modify `workflow-gate.js`.
