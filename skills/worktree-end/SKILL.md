---
name: worktree-end
description: Inventory gitignored state, merge PR, and clean up a git worktree after task completion
user-invocable: false
---

Inventory gitignored state, merge the PR, then remove the worktree safely.

## Procedure

When a hook blocks a sanctioned command, a fallback path is taken, or any unexpected outcome occurs, report via supervisor-report — see rules/supervisor-reporting.md.

### Step WE-1 — Resolve <PLANS_DIR>
`PLANS_DIR="$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir")"` — run once; reuse. Canonical: `skills/_shared/resolve-plans-dir.md`.

### Step WE-2 — Pre-flight
- `gh --version` — abort with installation guidance if not found.
- Verify linked worktree: `git rev-parse --git-common-dir` must differ from `git rev-parse --git-dir`; if equal, abort.

### Step WE-3 — Unstaged tracked-file check
Run `bash "$AGENTS_CONFIG_DIR/bin/check-unstaged-tracked.sh" "$WORKTREE_PATH"`. rc=0 → continue. rc=1 → display stdout and abort (`git add` / `git stash push -u` / `<<WORKFLOW_ENFORCE_WORKFLOW_OFF: <reason>>>` to bypass). rc=2/3 → surface stderr and abort. Skip when WORKFLOW_OFF or WORKTREE_OFF session marker is active.

### Step WE-4 — PR resolution
Bootstrap probe: `PROBE_JSON="$(bash "$AGENTS_CONFIG_DIR/bin/probe-remote-bootstrap.sh" "$WORKTREE_PATH")"`. `preBootstrap === true` AND `classification === "empty-repo"` → WE-4b. Any other classification → normal flow.

Push (`git push -u origin <branch>`), then `gh pr view --json state,url` — reuse if `OPEN`, else `gh pr create --fill`. Display URL. Capture `PR_NUMBER=$(gh pr view --json number --jq .number)`; abort if empty.

### Step WE-4b — Bootstrap mode (empty-repo only)
1. `bash "$AGENTS_CONFIG_DIR/skills/worktree-end/scripts/bootstrap-complete.sh" "$WORKTREE_PATH" "$BRANCH" "$OWNER_REPO"` — parse `BOOTSTRAP_COMMIT_SHA` and `DEFAULT_BRANCH_SET`. Non-zero → stop.
2. Set `BOOTSTRAP_MODE=1`, `PR_NUMBER=""`, `PR_STATE="BOOTSTRAP"`.
3. Emit `<<WORKFLOW_USER_VERIFIED: bootstrap initial commit pushed to main>>` via `skills/_shared/user-verified.md`.
4. Skip WE-5 through WE-8; continue at WE-9, WE-12 (with `BOOTSTRAP_MODE=1` and `BOOTSTRAP_COMMIT_SHA`), WE-15.

### Step WE-5 — Merge decision
`gh pr view "$PR_NUMBER" --json state --jq .state`: `MERGED` → WE-7. `CLOSED` → error and stop. `OPEN` → continue. other/error/empty → error and stop.

Check `AUTO_MERGE_PR`: `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" AUTO_MERGE_PR on'`. `ON`/`ERROR` → announce and proceed to WE-8. `OFF` → `AskUserQuestion` "PR #<N> — merge, wait-for-web-merge, or abort?" → WE-8 / WE-6 / stop. Default **wait-for-web-merge** when AskUserQuestion unavailable.

### Step WE-6 — Web-merge wait
Display URL; stop. On reply: `gh pr view "$PR_NUMBER" --json state` — `MERGED` → WE-7; else re-display and stop.

### Step WE-7 — Post-web-merge sync
`git fetch --prune origin`, then emit user-verified sentinel via `skills/_shared/user-verified.md` (description: `"User confirmed PR #<N> merged via web UI"`) → WE-9.

### Step WE-8 — Local merge
Emit user-verified sentinel via `skills/_shared/user-verified.md` (description: `"PR #<N> — approving merge to main"`), then `gh pr merge --squash --delete-branch`. Failure → surface error and stop.

### Step WE-9 — Gitignored state inventory
Default backup dir: `<main_root>/.worktree-backup/<branch>/`.

**Pass 1 — dry run**: `Agent({ subagent_type: "worktree-backup-worker", prompt: JSON.stringify({ mode: "dry_run", worktree_path: WORKTREE_PATH, branch: BRANCH, backup_dir: BACKUP_DIR, docker_check: true, artifact_dir: PLANS_DIR }) })`. `status: failed` → stop. File count 0 → `BACKUP_MANIFEST_PATH=(none)`, skip Pass 2.

**Pass 2 — execute**: `Agent({ subagent_type: "worktree-backup-worker", prompt: JSON.stringify({ mode: "execute", worktree_path: WORKTREE_PATH, branch: BRANCH, backup_dir: BACKUP_DIR, docker_check: true, artifact_dir: PLANS_DIR }) })`. `status: failed` → stop. `status: partial` → warn and continue. `status: copied` → set `BACKUP_MANIFEST_PATH` from worker `artifact_path`.

### Step WE-10 — Last-chance findings
Append any outstanding BugsFound / RelatedTasks / NextTasks to `<worktree>/WORKTREE_NOTES.md`. **Capture cutoff** — findings after this step are excluded from the Final Report.

### Step WE-11 — Promote WORKTREE_NOTES entries to issues
Skip when `bash "$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"` fails. List: `node "$AGENTS_CONFIG_DIR/bin/worktree-notes-triage.js" list "$WORKTREE_PATH/WORKTREE_NOTES.md"`, filter `hasMarker: false`. Empty or non-interactive → WE-12.

Confirm via AskUserQuestion (multi-select). For each selected: invoke `/issue-create`; annotate via `node "$AGENTS_CONFIG_DIR/bin/worktree-notes-triage.js" annotate ...`. `## History Notes` / `## Changelog Notes` are excluded.

### Step WE-12 — Env collection + JSON persist
Resolve `SID`: `awk '/^Session-ID:/{sub(/^Session-ID:[[:space:]]*/,""); sub(/\r/,""); print; exit}' "$WORKTREE_PATH/WORKTREE_NOTES.md"` → fallback `$CLAUDE_SESSION_ID`.
Run as **one Bash call**: `bash "$AGENTS_CONFIG_DIR/skills/worktree-end/scripts/capture-env.sh" "<worktree>" "<owner>/<repo>" "<backup-dir>" "$SID"` → output: `$PLANS_DIR/$SID-final-report-env.json`.
Run: `node "$AGENTS_CONFIG_DIR/bin/supervisor-write-alert" --session-id "$SID" --set-alert-eligible-phase post_final_report_window`.

### Step WE-13 — Switch CWD to main worktree
Resolve main root from the worktree's `.git` file. `cd "<main-worktree-root>"` as its own Bash call (releases Windows CWD lock).

### Steps WE-15..WE-22 — Cleanup cascade
`bash "$AGENTS_CONFIG_DIR/skills/worktree-end/scripts/cleanup-cascade.sh"` — orchestrator issues each command separately. Run only after confirmed merge and inventory.

## Rules
- Cleanup runs only after confirmed merge (or bootstrap-complete.sh exit 0 in WE-4b). No destructive steps on wait/abort/error paths.
- `git worktree remove --force` is prohibited; see `rules/ops.md`.
- `git branch -D` (WE-19 only) requires inline `WORKTREE_END_SKILL=1` env prefix.
- `<<WORKFLOW_USER_VERIFIED>>` emitted in WE-8 (before merge), WE-7 (post-web-merge), or WE-4b (bootstrap). Never on abort or while polling. Protocol: `skills/_shared/user-verified.md`.
- `AUTO_MERGE_PR=on` skips AskUserQuestion in WE-5 (worktree mode only).
- Secret values must not appear in the backup manifest.
- Use `hooks/cleanup-orphan-dir.js` for orphan directory cleanup — never `rm -rf`.
- Step WE-12 must execute as one Bash tool call; do not split.
- Step WE-3 honors WORKFLOW_OFF / WORKTREE_OFF session markers.
- On fallback or step degradation: `node "$AGENTS_CONFIG_DIR/bin/supervisor-report" --categories workflow --severity warning --detail "<describe fallback>" --reporter worktree-end`.
