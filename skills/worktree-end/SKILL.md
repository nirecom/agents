---
name: worktree-end
description: Inventory gitignored state, merge PR, and clean up a git worktree after task completion
user-invocable: false
---

Inventory and preserve gitignored state, merge the PR, then remove the worktree safely.

## Procedure

### Step 0 — Resolve <PLANS_DIR>

Before any tool call below that references <PLANS_DIR>, run the following Bash command exactly once:

```bash
PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
              || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")
printf 'PLANS_DIR=%s\n' "$PLANS_DIR"
```

Capture the printed absolute path and substitute it for every <PLANS_DIR>
placeholder in the remainder of this SKILL.md. Subagent prompts must receive
the resolved absolute path as a literal string (subagents cannot expand $VAR).
Reuse across all subsequent steps in this skill invocation — do not re-resolve.

Canonical documentation: skills/_shared/resolve-plans-dir.md.

1. **Pre-flight checks:**
   - If `--resume` flag is present:
     ```
     node bin/worktree-end-resume-load.js --plans-dir <PLANS_DIR>
     ```
     Exit after resume completes (exit 0) or fails (exit 1). Skip steps 2–6 entirely.
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

   **PR state gate** (runs before AUTO_MERGE_PR check — applies to both on/off modes):
   `gh pr view "$PR_NUMBER" --json state --jq .state`
   - `MERGED` → step 3b (skip AUTO_MERGE_PR check and step 4).
   - `CLOSED` → surface error "PR #<N> was closed without merging." and stop.
   - `OPEN` → continue below.
   - error / empty / any other state → surface error "Unable to determine PR #<N> state." and stop.

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
   Follow `skills/_shared/user-verified.md` to emit the sentinel
   (description: `"User confirmed PR #<N> merged via web UI"`). The PreToolUse hook
   re-surfaces the PR URL above the permission dialog.
   → step 5. Skip step 4.

4. **Local merge:**

   Follow `skills/_shared/user-verified.md` to emit the sentinel
   (description: `"PR #<N> — approving merge to main"`). The PreToolUse hook
   surfaces the PR URL above the permission dialog so the user approves from
   an informed position. Then:
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
      - `<repo-id>` = output of (hook path and main-root passed as argv — platform-safe):
        ```
        node -e "const {getRepoId}=require(process.argv[1]); const id=getRepoId(process.argv[2]); if(!id){process.stderr.write('getRepoId failed\n');process.exit(1);}console.log(id);" -- "$AGENTS_CONFIG_DIR/hooks/enforce-worktree.js" "<absolute-main-root>"
        ```
        If the command exits non-zero, abort — do not proceed with a null repo-id.
      - `<encoded-branch>` = `encodeURIComponent(<branch>)` (e.g. `feature/foo` → `feature%2Ffoo`).
      - `<plans>` = `<PLANS_DIR>` (resolved via Step 0 at top of Procedure).
      - `<marker-path>` = `<plans>/worktree-end/pending-branch-delete-<repo-id>--<encoded-branch>`. Store for step g.
      - Content (two lines): `<branch>` / `<absolute-worktree-path>` (must resolve under `WORKTREE_BASE_DIR`).
      - Use the Write tool (atomic; auto-creates `worktree-end/` on first use).
   b.5. **Switch the session CWD to the main worktree** before step 6c.
      Run as its own Bash call (literal absolute path — no `$VAR` / `~`):
      ```
      cd "<main-worktree-root>"
      ```
      `cd` (not `git -C`) is required: it updates the Bash tool's CWD,
      releasing the Windows CWD lock (#251) and keeping `process.cwd()`
      healthy so `enforce-worktree.js` does not mis-classify subsequent
      commands (#268, #321). The combined form
      `cd "<main>" && git -C "<main>" worktree remove "<path>"` is also
      permitted via `isAllowedCdWorktreeRemove` for Windows/VS Code where
      the Bash CWD resets between calls (#294).
   b.6. **Write deferred-cleanup marker** (`pending-cwd-unlock-`):
      Compute marker path via `getMarkerPath(mainRoot, branch, MARKER_PREFIXES.CWD_UNLOCK)`.
      Write 3-line content (Use the Write tool — atomic; auto-creates `worktree-end/` on first use):
      ```
      <branch>
      <absolute-worktree-path>
      pre-remove
      ```
      This marker authorises `/worktree-end --resume` to complete cleanup in a new session.
      Note: the existing `pending-branch-delete-` marker (step b) is kept on disk — it is
      required to authorise `git branch -D` in the resume path (Risk #16).
   c. `git -C <main> worktree remove <path>` (never `--force` — see rules).
   c.1. **Deferred-fork graceful exit** (Windows; only on EPERM / "busy" /
      "not empty" from step 6c). The `pending-cwd-unlock-` marker written in
      step b.6 is already on disk. Display:
      ```
      Worktree removal deferred.
      Run /worktree-end --resume in a new session to complete cleanup.
      ```
      Stop. Do NOT delete the marker here — the next session reads it.
   d. `git -C <main> worktree prune`
   e. **Orphan-dir cleanup** at `<WORKTREE_BASE_DIR>/<task-name>`:
      ```
      node "$AGENTS_CONFIG_DIR/hooks/cleanup-orphan-dir.js" "<WORKTREE_BASE_DIR>/<task-name>"
      ```
      If it refuses with "not empty" (Windows recreated files after 6c),
      re-run with `--force-if-not-registered` — requires the step 5
      inventory to be complete (issue #322).
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
  (after `state == MERGED`), via `skills/_shared/user-verified.md`. Never on abort
  or while polling.
- Step 3 PR state gate runs before the AUTO_MERGE_PR check; applies to both on/off modes; `MERGED` always routes to step 3b.
- `AUTO_MERGE_PR=on` skips `AskUserQuestion` in step 3 (worktree mode only).
- `$PR_NUMBER` captured in step 2; used explicitly in step 3a. Session-local only.
- This skill does NOT modify `workflow-gate.js`.
