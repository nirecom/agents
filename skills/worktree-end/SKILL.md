---
name: worktree-end
description: Inventory gitignored state, merge PR, and clean up a git worktree after task completion
user-invocable: false
---

Inventory and preserve gitignored state, merge the PR, then remove the worktree safely.

## Procedure

### Step 0 — Resolve <PLANS_DIR>

`PLANS_DIR="$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir")"` — run once; reuse for the rest of the skill. Canonical: `skills/_shared/resolve-plans-dir.md`.

1. **Pre-flight checks:**
   - `gh --version` — abort with installation guidance if gh is not found.
   - Verify cwd is inside a linked worktree (not the main worktree):
     `git rev-parse --git-common-dir` must differ from `git rev-parse --git-dir`.
     If they are equal, abort: the user must `cd` into the worktree first.

2. **PR resolution (idempotent):** push (`git push -u origin <branch>`), then `gh pr view --json state,url` — reuse if `OPEN`, else `gh pr create --fill`. Display the URL. Capture `PR_NUMBER=$(gh pr view --json number --jq .number)`; abort if empty.

3. **Merge decision:**

   PR state gate (runs before AUTO_MERGE_PR; applies to both modes): `gh pr view "$PR_NUMBER" --json state --jq .state`
   - `MERGED` → step 3b (skip AUTO_MERGE_PR and step 4).
   - `CLOSED` → error "PR #<N> was closed without merging." and stop.
   - `OPEN` → continue. Output `PR #<N> is open: [<url>](<url>)`.
   - other/error/empty → error "Unable to determine PR #<N> state." and stop.

   Check `AUTO_MERGE_PR` (default `on`): `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off AUTO_MERGE_PR on && echo OFF || echo ON'`.
   - `on`: announce `AUTO_MERGE_PR=on → merging now.` → step 4.
   - `off`: `AskUserQuestion` "PR #<N> — merge, wait-for-web-merge, or abort?" → step 4 / 3a / stop. If `AskUserQuestion` unavailable, default to **wait-for-web-merge**.

3a. **Web-merge wait:** display `PR #<N>: merge via GitHub UI, then reply here.` + URL; stop. On reply: `gh pr view "$PR_NUMBER" --json state` — `MERGED` → 3b; else re-display and stop. `$PR_NUMBER` is session-local.

3b. **Post-web-merge sync:** `git fetch --prune origin`, then emit the user-verified sentinel **directly** with no preceding narrative (hook surfaces context — see `skills/_shared/user-verified.md`; description: `"User confirmed PR #<N> merged via web UI"`) → step 5. Skip step 4.

4. **Local merge:** emit the user-verified sentinel **directly** with no preceding narrative — do not restate the PR URL or describe the approval in chat first. The hook (`hooks/show-user-verified-context.js`) surfaces the PR URL and the approval instruction above the permission dialog. Use `skills/_shared/user-verified.md` (description: `"PR #<N> — approving merge to main"`), then `gh pr merge --squash --delete-branch`. On failure: surface error and stop — do NOT force-merge or bypass checks.

5. **Gitignored state inventory** (before removing the worktree):

   Default backup destination: `<main_root>/.worktree-backup/<branch>/` (gitignored via `.git/info/exclude`).

   **Pass 1 — dry run**: delegate inventory to `worktree-backup-worker`:
   ```
   Agent({ subagent_type: "worktree-backup-worker", prompt: JSON.stringify({
     mode: "dry_run", worktree_path: WORKTREE_PATH, branch: BRANCH,
     backup_dir: BACKUP_DIR, docker_check: true, artifact_dir: PLANS_DIR
   }) })
   ```
   Worker returns one-line summary. Present to user via `AskUserQuestion`: "Back up (copy to .worktree-backup/), discard, or abort?"

   **Pass 2 — execute** (only when user chose "back up"):
   Set:
   ```
   BACKUP_DIR="<main_root>/.worktree-backup/<branch>/"
   ```
   ```
   Agent({ subagent_type: "worktree-backup-worker", prompt: JSON.stringify({
     mode: "execute", worktree_path: WORKTREE_PATH, branch: BRANCH,
     backup_dir: BACKUP_DIR, docker_check: true, artifact_dir: PLANS_DIR
   }) })
   ```
   Worker returns `artifact_path` (manifest.json). Set:
   ```
   BACKUP_MANIFEST_PATH="<artifact_path from worker>"
   ```

   If user chose "discard" and no files were copied, set `BACKUP_MANIFEST_PATH=(none)`.
   If Docker containers reference the worktree path, stop them and restart from the main path.

### Step 5.5

5.5. **Capture for Final Report** (must run before Step 6c — worktree removal):

   a. Last-chance findings review: append outstanding bugs/related/next-task findings to `<worktree>/WORKTREE_NOTES.md`. **This is the capture cutoff** — findings after Step 5.5 will not appear in the Final Report.

   (a.5) **Fallback path** — issue-create promotion for unconverted WORKTREE_NOTES.md entries (entries written via the fallback path of `CLAUDE.md` `## Mid-workflow finding capture`). The primary path is `/issue-create` at discovery time; this step is the safety net only.

     1. Skip silently when `bash "$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"` fails.
        List candidates: `node "$AGENTS_CONFIG_DIR/bin/worktree-notes-triage.js" list "$WORKTREE_PATH/WORKTREE_NOTES.md"` and filter to entries with `hasMarker: false`. Empty list → skip to (b).
        Non-interactive (claude -p): emit stderr warning `[worktree-end] WARN: N WORKTREE_NOTES entries not promoted (non-interactive)` and skip to (b).
     2. Confirm selection via AskUserQuestion (multi-select).
     3. For each selected entry (sequential, not parallel):
        a. Invoke `/issue-create`.
        b. Extract issue number: `N=$(echo "$OUTPUT" | tail -n 1 | tr -d '\r' | grep -oE '[0-9]+$')`.
        c. Annotate: `node "$AGENTS_CONFIG_DIR/bin/worktree-notes-triage.js" annotate "$WORKTREE_PATH/WORKTREE_NOTES.md" "$LINE_NUMBER" "$N"`.
        d. On `/issue-create` failure: stderr warning, skip annotate, next entry.
     (a.5) must complete before (b) so annotations land in the backup. `## History Notes` / `## Changelog Notes` are NOT triage targets.

   **(b–d) — env collection + JSON persist (single Bash call):**

   ```bash
   # Single Bash call — atomicity contract enforced inside capture-env.sh. Do not split.
   # Output: $PLANS_DIR/<session-id>-final-report-env.json
   export PLANS_DIR
   bash "$AGENTS_CONFIG_DIR/skills/worktree-end/scripts/capture-env.sh" \
     "<worktree>" "<owner>/<repo>" "<backup-dir>" "<session-id>"
   ```

### Step 6

6. **Cleanup** (only after confirmed merge success and inventory — never before):
   a. Resolve the main repo root from the worktree's `.git` file.
   b. **Switch the session CWD to the main worktree** before step 6c (releases Windows CWD lock #251; keeps `process.cwd()` healthy #268, #321). Run as its own Bash call (literal absolute path):
      ```
      cd "<main-worktree-root>"
      ```
   c. `git -C <main> worktree remove <path>` (never `--force` — see rules).
   c.1. On non-zero exit (EPERM, busy, not-empty, any error): print stderr warning that `/sweep-worktrees` will reclaim the directory and branch automatically; skip 6e and 6f; proceed to 6g. (6e skipped: dir occupied — self-resolves at next sweep. 6f skipped: git cascade rule blocks `branch -D` while worktree registered.)
   d. `git -C <main> worktree prune`
   e. **Orphan-dir cleanup** at `<WORKTREE_BASE_DIR>/<task-name>`:
      ```
      node "$AGENTS_CONFIG_DIR/hooks/cleanup-orphan-dir.js" "<WORKTREE_BASE_DIR>/<task-name>"
      ```
      If it refuses with "not empty", re-run with `--force-if-not-registered` (requires step 5 inventory complete — issue #322).
   f. `WORKTREE_END_SKILL=1 git -C <main> branch -D <branch>` — `-D` required because squash-merge produces a new commit not recognised by `-d`'s fully-merged check. The inline `WORKTREE_END_SKILL=1` is the authorization token for `enforce-worktree.js`.
   g. `git -C <main> fetch --prune origin`
      `git -C <main> pull --ff-only`
   h. **Compose doc-append** (main worktree; only when NOTES_BACKUP_PATH is non-empty).
      Parse `closes_issues` from `<PLANS_DIR>/<session-id>-intent.md`. Non-empty → set `skip_history: true` (history.md already committed by Phase 1/2). Empty / missing → `skip_history: false` (CLI bails exit 0 if notes sections empty).
      Delegate to doc-append-worker:
      `Agent({ subagent_type: "doc-append-worker", prompt: JSON.stringify({ mode: "compose", notes_path: NOTES_BACKUP_PATH, branch: BRANCH, pr_number: PR_NUMBER, merge_commit: MERGE_SHA, pr_title: PR_TITLE, skip_history: SKIP_HISTORY, cwd: MAIN_ROOT, agents_config_dir: AGENTS_CONFIG_DIR, artifact_dir: PLANS_DIR }) })`
      On `failed` status: surface `artifact_path` to the user; Step 6i still runs. Push-failure recovery: `COMPOSE_DOC_APPEND_SKILL=1 git push origin main`. CLI idempotency prevents duplicates on retry.
   i. Verify cleanup: `git -C <main> worktree list` — confirm no stale entries.
## Rules

- **wait / abort paths: no destructive steps.** Only merge-success path runs cleanup.
- `git worktree remove --force` is prohibited (see `rules/ops.md` decision path).
- Branch deletion (`git branch -D`) only in step 6f, allowed via the inline `WORKTREE_END_SKILL=1` env prefix (enforce-worktree gates `-D` on skill authorization; non-force `-d` allowed for any branch not checked out per `git worktree list --porcelain`).
- Do not run cleanup if merge step failed or was skipped.
- Always propose `.worktree-backup/<branch>/` as the default backup destination.
- Always check stopped containers, not just running ones, for bind mount conflicts.
- Secret values must not appear in the backup manifest.
- Use `hooks/cleanup-orphan-dir.js` for orphan directory cleanup (6e) — never `rm -rf`/`Remove-Item -Recurse -Force`.
- `gh --version` must succeed before any gh command.
- `<<WORKFLOW_USER_VERIFIED: <reason>>>` is emitted in step 4 (before `gh pr merge`) or step 3b (after `state == MERGED`), via `skills/_shared/user-verified.md`. Never on abort or while polling.
- Step 3 PR state gate runs before the AUTO_MERGE_PR check; applies to both on/off modes; `MERGED` always routes to step 3b.
- `AUTO_MERGE_PR=on` skips `AskUserQuestion` in step 3 (worktree mode only).
- `$PR_NUMBER` captured in step 2; used explicitly in step 3a. Session-local only.
- This skill does NOT modify `workflow-gate.js`.
<<<<<<< HEAD
- Step 5.5 invariants: see `skills/worktree-end/scripts/capture-env.sh` header (atomicity / BRANCH_DELETED omission / four restart categories).
- Step 7 sentinel check is mandatory; absence of `<<WORKFLOW_MARK_STEP_final_report_complete>>` in renderer output = failure. No silent fallback, no hand-written Markdown.
- Step 7 MUST read `NOTES_BACKUP_PATH` from the JSON via the read-notes-path.js helper, not from a shell variable (shell vars don't survive Windows Bash tool call boundaries).
- Step 7 MUST invoke renderer with `--env-file $PLANS_DIR/<session-id>-final-report-env.json`.
- Final Report verbatim output: paste renderer stdout (sentinel line excluded) character-for-character into the assistant message — no formatting changes.
- Do not delete, transform, summarize, or reorder any heading (`## Final Report` or `### ...`) in the Final Report.
- Do not reformat Final Report section content into prose (e.g., writing `Closed Issues: #N` instead of the `### Closed Issues` heading followed by `- #N`).
=======
- Step 5.5 (b–d) MUST execute as one Bash tool call (survives Windows env reset, #504). Do not split into separate calls.
- Step 5.5 JSON output MUST NOT include `BRANCH_DELETED` (accuracy fix tracked separately; renderer renders `(none)` as fail-safe, #504).
- Step 5.5 JSON output MUST include all four post-merge action categories (cc_restart / vscode_reload / installer_rerun / os_reboot). CLAUDE_CODE_RESTART_REQUIRED is kept as deprecated alias for backward compat.
>>>>>>> a7c1092 (feat(#608): add /session-close skill — Final Report after issue-close-finalize)
