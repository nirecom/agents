---
name: worktree-end
description: Inventory gitignored state, merge PR, and clean up a git worktree after task completion
user-invocable: false
---

Inventory gitignored state, merge the PR, then remove the worktree safely.

## Procedure

When a hook blocks a sanctioned command, a fallback path is taken, or any unexpected outcome occurs, report via /supervisor-report (trigger conditions: rules/supervisor-reporting.md).

Read `rules/github-issues.md` before WE-4 — on-demand-only, never auto-injected; WE-4..WE-8 and WE-11 depend on it.
Read `rules/mid-workflow-findings.md` before WE-10 — on-demand-only, never auto-injected; WE-10 depends on its append CLI and severity tagging.
Read `rules/coding.md` before WE-4 — on-demand-only, never auto-injected; its Public GitHub Rules govern the PR body, issue comments, and history entries written from here on.

### Step WE-1 — Resolve <PLANS_DIR>
Run `bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"` once as one bare command and reuse its printed path — never assign it to a shell variable, which does not survive to the next Bash call. Canonical: `skills/_shared/resolve-plans-dir.md`.

### Step WE-2 — Pre-flight
- `gh --version` — abort with installation guidance if not found.
- Verify linked worktree: `git rev-parse --git-common-dir` must differ from `git rev-parse --git-dir`; if equal, abort.

### Step WE-3 — Unstaged tracked-file check
Run `bash "$AGENTS_CONFIG_DIR/bin/check-unstaged-tracked.sh" "$WORKTREE_PATH"`. rc=0 → continue. rc=1 → display stdout and abort (`git add` / `git stash push -u` / `<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>` to bypass). rc=2/3 → surface stderr and abort. Skip when WORKFLOW_OFF or WORKTREE_OFF session marker is active.

### Step WE-4 — PR resolution
Bootstrap probe: `PROBE_JSON="$(bash "$AGENTS_CONFIG_DIR/bin/probe-remote-bootstrap.sh" "$WORKTREE_PATH")"`. `preBootstrap === true` AND `classification === "empty-repo"` → WE-4b. Any other classification → normal flow.

Push (`git push -u origin <branch>`), then `gh pr view --json state,url` — reuse if `OPEN`, else `gh pr create --fill`. Display URL. Capture `PR_NUMBER=$(gh pr view --json number --jq .number)`; abort if empty.

### Step WE-4b — Bootstrap mode (empty-repo only)
1. `bash "$AGENTS_CONFIG_DIR/skills/worktree-end/scripts/bootstrap-complete.sh" "$WORKTREE_PATH" "$BRANCH" "$OWNER_REPO"` — parse `BOOTSTRAP_COMMIT_SHA` and `DEFAULT_BRANCH_SET`. Non-zero → stop.
2. Set `BOOTSTRAP_MODE=1`, `PR_NUMBER=""`, `PR_STATE="BOOTSTRAP"`.
3. Emit `<<WORKFLOW_USER_VERIFIED: bootstrap initial commit pushed to main>>` via `skills/_shared/user-verified.md`.
4. Skip WE-5 through WE-8; continue at WE-9, WE-12 (with `BOOTSTRAP_MODE=1` and `BOOTSTRAP_COMMIT_SHA`), WE-15.

### Step WE-5 — Merge decision
`gh pr view "$PR_NUMBER" --json state --jq .state`: `MERGED` → WE-7 (the merge happened outside this session's WE-8 — Web UI or another client — so WE-7 is the detection path for it). `CLOSED` → error and stop. `OPEN` → continue. other/error/empty → error and stop.

Check `AUTO_MERGE_PR`: `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" AUTO_MERGE_PR on'`. `ON`/`ERROR` → announce and proceed to WE-8. `OFF` → `AskUserQuestion` "PR #<N> — merge, wait-for-web-merge, or abort?" → WE-8 / WE-6 / stop. Default **wait-for-web-merge** when AskUserQuestion unavailable.

### Step WE-6 — Web-merge wait
Display URL; stop. On reply: `gh pr view "$PR_NUMBER" --json state` — `MERGED` → WE-7; else re-display and stop.

### Step WE-7 — Post-web-merge sync
`git fetch --prune origin`, then emit user-verified sentinel via `skills/_shared/user-verified.md` (description: `"User confirmed PR #<N> merged via web UI"`) → WE-9.
Skip the sentinel and go straight to WE-9 when this session already recorded `user_verification` as complete for this merge — check `node "$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session "$SID"` and treat a `REASON=` other than `user_verification` as already-recorded. Keep CWD in the linked worktree throughout WE-7; do not switch to main worktree before WE-13.

### Step WE-8 — Local merge
Emit user-verified sentinel via `skills/_shared/user-verified.md` (description: `"PR #<N> — approving merge to main"`), then `gh pr merge --squash --delete-branch`. Failure → surface error and stop. Keep CWD in the linked worktree throughout WE-8; do not switch to main worktree before WE-13.

### Step WE-9 — Gitignored state inventory
Backup dir is derived by the worker as `<main_root>/.worktree-backup/<branch>/` — never passed in.

Both passes dispatch the `worktree-backup` worker per `skills/_shared/worker-dispatch.md` with payload `worktree_path` / `branch` / `docker_check: true` / `artifact_dir`, differing only in `mode`. Use payload sequence suffixes `-1` and `-2` so Pass 1's file is not overwritten.

Serial by dependency (SC-S): Pass 2 copies exactly the file set Pass 1 inventoried and reported — a parallel Pass 2 would act on an uninventoried set and both passes write the same backup directory. See `skills/_shared/subagent-concurrency.md`.

**Pass 1 — `mode: "dry_run"`**: `status: failed` → stop. File count 0 → `BACKUP_MANIFEST_PATH=(none)`, skip Pass 2.

**Pass 2 — `mode: "execute"`**: `status: failed` → stop. `status: partial` → warn and continue. `status: copied` → set `BACKUP_MANIFEST_PATH` from `artifact_path`.

### Step WE-10 — Last-chance findings
Append any outstanding BugsFound / RelatedTasks / NextTasks to `<worktree>/WORKTREE_NOTES.md`. **Capture cutoff** — findings after this step are excluded from the Final Report.
Use the append CLI and severity tagging per `rules/mid-workflow-findings.md`.

### Step WE-11 — Promote WORKTREE_NOTES entries to issues
Run the pass in `skills/_shared/notes-promotion.md` unconditionally at this step — the worktree and its notes are deleted later in this skill, so no downstream callsite can reach them.

Resolve the path with `node "$AGENTS_CONFIG_DIR/bin/worktree-notes-triage.js" resolve --caller worktree-end --worktree "$WORKTREE_PATH"`, then follow NP-1..NP-11 as written.

`## History Notes` / `## Changelog Notes` are excluded from the pass. Continue to WE-12 in every outcome.

### Step WE-12 — Env collection + JSON persist
Resolve `SID`: `awk '/^Session-ID:/{sub(/^Session-ID:[[:space:]]*/,""); sub(/\r/,""); print; exit}' "$WORKTREE_PATH/WORKTREE_NOTES.md"` → fallback `$CLAUDE_SESSION_ID`.
Run as **one Bash call**: `bash "$AGENTS_CONFIG_DIR/skills/worktree-end/scripts/capture-env.sh" "<worktree>" "<owner>/<repo>" "<backup-dir>" "$SID"` → output: `$PLANS_DIR/$SID-final-report-env.json`.
Run: `node "$AGENTS_CONFIG_DIR/bin/supervisor-write-alert" --session-id "$SID" --set-alert-eligible-phase post_final_report_window`.

### Step WE-13 — Switch CWD to main worktree
Resolve main root from the worktree's `.git` file. `cd "<main-worktree-root>"` as its own Bash call (releases Windows CWD lock).

### Step WE-13a — Release the session worktree binding
Call the native `ExitWorktree` tool after the WE-13 `cd` to release the extension host's session worktree binding; skip silently when that tool is unavailable.
Protocol: `skills/_shared/worktree-transition.md`

### Steps WE-15..WE-22 — Cleanup cascade
Read `rules/ops.md` before the first destructive step (it is on-demand-only and never auto-injected): it owns the recovery-options-first decision path every deletion here must pass through.
Read `$AGENTS_CONFIG_DIR/skills/worktree-end/scripts/cleanup-cascade.md` (spec) and issue each command separately. Run only after confirmed merge and inventory.
If WE-15 is blocked (CWD lock / busy), WORKTREE_OFF is NOT needed — /sweep-worktrees auto-reclaims; follow WE-16 and continue to WE-20.
Cleanup-active marker (WE-14b create → WE-22a delete) brackets the window so the
supervisor OFF-block adaptive message fires only during WE-15..WE-22 — see cleanup-cascade.md.
WE-14c releases the CodeGraph index lock immediately before WE-15 — see cleanup-cascade.md.

## Rules
- Cleanup runs only after confirmed merge (or bootstrap-complete.sh exit 0 in WE-4b). No destructive steps on wait/abort/error paths.
- `git worktree remove --force` is prohibited; blocked at the `settings.json` deny layer, not by prose in `rules/ops.md`.
- The worktree/workflow escape-hatch sentinels must NOT be emitted to unblock WE-15; /sweep-worktrees reclaims — proceed to WE-20 (WE-16 fallback).
- `ExitWorktree` is called only at WE-13a — never before the WE-13 `cd`.
- `git branch -D` (WE-19 only) requires inline `WORKTREE_END_SKILL=1` env prefix.
- `<<WORKFLOW_USER_VERIFIED>>` emitted in WE-8 (before merge), WE-7 (post-web-merge), or WE-4b (bootstrap). Never on abort or while polling. Protocol: `skills/_shared/user-verified.md`.
- CWD must remain in the linked worktree from WE-7/WE-8 through WE-12; switch to main worktree only at WE-13.
- `AUTO_MERGE_PR=on` skips AskUserQuestion in WE-5 (worktree mode only).
- Secret values must not appear in the backup manifest.
- Use `hooks/cleanup-orphan-dir.js` for orphan directory cleanup — never `rm -rf`.
- Step WE-12 must execute as one Bash tool call; do not split.
- Step WE-3 honors WORKFLOW_OFF / WORKTREE_OFF session markers.
- On fallback or step degradation: `node "$AGENTS_CONFIG_DIR/bin/supervisor-report" --categories workflow --severity warning --detail "<describe fallback>" --reporter worktree-end`.
