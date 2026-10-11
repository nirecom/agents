---
name: worktree-end
description: Inventory gitignored state and clean up a git worktree after the delivery is complete
user-invocable: false
---

Inventory gitignored state, then remove the worktree safely once `/deliver` has delivered the change.

## Procedure

When a hook blocks a sanctioned command, a fallback path is taken, or any unexpected outcome occurs, report via /supervisor-report (trigger conditions: rules/supervisor-reporting.md).

Read `rules/github-issues.md` before WE-4 — on-demand-only, never auto-injected; WE-4 and WE-7 depend on it.
Read `rules/mid-workflow-findings.md` before WE-6 — on-demand-only, never auto-injected; WE-6 depends on its append CLI and severity tagging.
Read `rules/coding.md` before WE-4 — on-demand-only, never auto-injected; its Public GitHub Rules govern the issue comments and history entries written from here on.

### Precondition — delivery settled
Run `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --session "<session-id>"`. `REASON=` other than `cleanup` (deliver not settled) → stop and follow its `ACTION`; never merge or push from this skill.

### WE-1 — Resolve <PLANS_DIR>
Run `bash "$AGENTS_MAIN_ROOT/bin/workflow-plans-dir"` once as one bare command and reuse its printed path — never assign it to a shell variable, which does not survive to the next Bash call. Canonical: `skills/_shared/resolve-plans-dir.md`.

### WE-2 — Pre-flight
- `gh --version` — abort with installation guidance if not found; for a gitlab remote (`node "$AGENTS_MAIN_ROOT/bin/detect-forge-type" --repo-dir . --field type` = `gitlab`) check `glab --version` instead.
- Verify linked worktree: `git rev-parse --git-common-dir` must differ from `git rev-parse --git-dir`; if equal, abort.

### WE-3 — Unstaged tracked-file check
Run `bash "$AGENTS_MAIN_ROOT/bin/check-unstaged-tracked.sh" "$WORKTREE_PATH"`. rc=0 → continue. rc=1 → display stdout and abort (`git add` / `git stash push -u` / `<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>` to bypass). rc=2/3 → surface stderr and abort. Skip when WORKFLOW_OFF or WORKTREE_OFF session marker is active.

### WE-4 — PR number resolution
Run `node "$AGENTS_MAIN_ROOT/bin/workflow/pr-state"` (read-only, any forge); read `PR_STATE=` and `<PR_NUMBER>` from `PR_NUMBER=`.
`PR_STATE=NONE` → bootstrap delivery (`/deliver` DL-3b pushed the branch as the default branch): set `BOOTSTRAP_MODE=1` and `BOOTSTRAP_COMMIT_SHA` from `git rev-parse HEAD` for WE-8.
`PR_STATE=UNKNOWN` (lookup failed) → stop and surface its stderr; never treat it as bootstrap.
Never push or create a PR here.

### WE-5 — Gitignored state inventory
Backup dir is derived by the worker as `<target_main_root>/.worktree-backup/<branch>/` — never passed in.

Resolve `dir_expand` once via `node "$AGENTS_MAIN_ROOT/skills/worktree-end/scripts/resolve-dir-expand.js"` (prints `true`/`false`) and pass its output to both passes.
Both passes dispatch the `worktree-backup` worker per `skills/_shared/worker-dispatch.md` with payload `worktree_path` / `branch` / `docker_check: true` / `dir_expand` / `artifact_dir`, differing only in `mode`. Use payload sequence suffixes `-1` and `-2` so Pass 1's file is not overwritten.

Serial by dependency (SC-S): both passes write the same backup directory. Pass 1 is an advisory preview; Pass 2 independently re-inventories live state at deletion time — it does not reuse Pass 1's file set. See `skills/_shared/subagent-concurrency.md`.

**Pass 1 — `mode: "dry_run"`**: `status: failed` → stop. Otherwise always proceed to Pass 2 (even when file count is 0, issues may require a partial manifest).

**Pass 2 — `mode: "execute"`**: `status: failed` → stop. `status: partial` → warn and continue. `status: copied` → set `BACKUP_MANIFEST_PATH` from `artifact_path`.
If the summary contains `NOT preserved`, emit an explicit data-loss warning to the user and prompt manual rescue before the cleanup cascade.

### WE-6 — Last-chance findings
Append any outstanding BugsFound / RelatedTasks / NextTasks to `<worktree>/WORKTREE_NOTES.md`. **Capture cutoff** — findings after WE-6 are excluded from the Final Report.
Use the append CLI and severity tagging per `rules/mid-workflow-findings.md`.

### WE-7 — Promote WORKTREE_NOTES entries to issues
Run the pass in `skills/_shared/notes-promotion.md` unconditionally in WE-7 — the worktree and its notes are deleted later in this skill, so no downstream callsite can reach them.

Resolve the path with `node "$AGENTS_MAIN_ROOT/bin/worktree-notes-triage.js" resolve --caller worktree-end --worktree "$WORKTREE_PATH"`, then follow NP-1..NP-11 as written.

`## History Notes` / `## Changelog Notes` are excluded from the pass. Continue to WE-8 in every outcome.

### WE-8 — Env collection + JSON persist
Resolve `SID`: `awk '/^Session-ID:/{sub(/^Session-ID:[[:space:]]*/,""); sub(/\r/,""); print; exit}' "$WORKTREE_PATH/WORKTREE_NOTES.md"` → fallback `$CLAUDE_CODE_SESSION_ID`.
Run as **one Bash call**: `bash "$AGENTS_MAIN_ROOT/skills/worktree-end/scripts/capture-env.sh" "<worktree>" "<owner>/<repo>" "<backup-dir>" "$SID"` (with `BOOTSTRAP_MODE` and `BOOTSTRAP_COMMIT_SHA` from WE-4 on a bootstrap delivery) → output: `<CONTROL_DIR>/final-report-env.json` (its last stdout line names the path).
Run: `node "$AGENTS_MAIN_ROOT/bin/supervisor-write-alert" --session-id "$SID" --set-alert-eligible-phase post_final_report_window`.

### WE-9 — Switch CWD to main worktree
Resolve main root from the worktree's `.git` file. `cd "<main-worktree-root>"` as its own Bash call (releases Windows CWD lock).

### WE-9a — Release the session worktree binding
Call the native `ExitWorktree` tool after the WE-9 `cd` to release the extension host's session worktree binding; skip silently when that tool is unavailable.
Protocol: `skills/_shared/worktree-transition.md`

### WE-11..WE-18 — Cleanup cascade
Read `rules/ops.md` before the first destructive step (it is on-demand-only and never auto-injected): it owns the recovery-options-first decision path every deletion here must pass through.
Read `$AGENTS_MAIN_ROOT/skills/worktree-end/scripts/cleanup-cascade.md` (spec) and issue each command separately. Run only after the settled delivery and inventory.
If WE-11 is blocked (CWD lock / busy), WORKTREE_OFF is NOT needed — /sweep-worktrees auto-reclaims; follow WE-12 and continue to WE-16.
Cleanup-active marker (WE-10b create → WE-18a delete) brackets the window so the
supervisor OFF-block adaptive message fires only during WE-11..WE-18 — see cleanup-cascade.md.
WE-10c releases the CodeGraph index lock immediately before WE-11 — see cleanup-cascade.md.

## Rules
- Cleanup runs only after `deliver` is settled (Precondition). No destructive steps on wait/abort/error paths.
- Never merge, push, or emit the release-approval sentinel here — `/get-release-approval` and `/deliver` own them.
- `git worktree remove --force` is prohibited; blocked at the `settings.json` deny layer, not by prose in `rules/ops.md`.
- The worktree/workflow escape-hatch sentinels must NOT be emitted to unblock WE-11; /sweep-worktrees reclaims — proceed to WE-16 (WE-12 fallback).
- `ExitWorktree` is called only at WE-9a — never before the WE-9 `cd`.
- `git branch -D` (WE-15 only) requires inline `WORKTREE_END_SKILL=1` env prefix.
- CWD must remain in the linked worktree through WE-8; switch to main worktree only at WE-9.
- Secret values must not appear in the backup manifest.
- Use `hooks/cleanup-orphan-dir.js` for orphan directory cleanup — never `rm -rf`.
- WE-8 must execute as one Bash tool call; do not split.
- WE-3 honors WORKFLOW_OFF / WORKTREE_OFF session markers.
- On fallback or step degradation: `node "$AGENTS_MAIN_ROOT/bin/supervisor-report" --categories workflow --severity warning --detail "<describe fallback>" --reporter worktree-end`.
