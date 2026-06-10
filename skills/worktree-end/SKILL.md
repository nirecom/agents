---
name: worktree-end
description: Inventory gitignored state, merge PR, and clean up a git worktree after task completion
user-invocable: false
---

Inventory and preserve gitignored state, merge the PR, then remove the worktree safely.

## Procedure

When a hook blocks a sanctioned command, a fallback path is taken, or any unexpected outcome occurs, report via supervisor-report — see rules/supervisor-reporting.md.

### Step WE-1 — Resolve <PLANS_DIR>
`PLANS_DIR="$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir")"` — run once; reuse. Canonical: `skills/_shared/resolve-plans-dir.md`.

### Step WE-2 — Pre-flight checks
- `gh --version` — abort with installation guidance if not found.
- Verify cwd is inside a linked worktree (not main worktree): `git rev-parse --git-common-dir` must differ from `git rev-parse --git-dir`. If equal, abort: user must `cd` into the worktree first.

### Step WE-2.5 — Unstaged tracked-file pre-flight
Run `bash "$AGENTS_CONFIG_DIR/bin/check-unstaged-tracked.sh" "$WORKTREE_PATH"`. rc=0 → continue. rc=1 → display stdout (modified file list) and abort with guidance: `git add` / `git stash push -u` / `<<WORKFLOW_ENFORCE_WORKFLOW_OFF: <reason>>>` to bypass. rc=2/3 → surface stderr and abort (no bypass — fail-safe). Skip this step entirely when WORKFLOW_OFF or WORKTREE_OFF session marker is active (parity with WE-2 enforce-worktree bypass).

### Step WE-3 — PR resolution (idempotent)

**Bootstrap probe (new-repo first commit):** Before pushing, probe the remote state: `PROBE_JSON="$(bash "$AGENTS_CONFIG_DIR/bin/probe-remote-bootstrap.sh" "$WORKTREE_PATH")"`. `preBootstrap === true` AND `classification === "empty-repo"` → skip to **WE-3b** (autonomous bootstrap, no PR). Any other classification (`ok`, `network`, `auth`, `not-found`, `timeout`, `spawn-error`, `unknown`) → continue with normal push/PR flow below.

Push (`git push -u origin <branch>`), then `gh pr view --json state,url` — reuse if `OPEN`, else `gh pr create --fill`. Display URL. Capture `PR_NUMBER=$(gh pr view --json number --jq .number)`; abort if empty.

### Step WE-3b — Autonomous bootstrap (no-PR mode)
Used only when Step WE-3 probe detected `empty-repo`.

1. `bash "$AGENTS_CONFIG_DIR/skills/worktree-end/scripts/bootstrap-complete.sh" "$WORKTREE_PATH" "$BRANCH" "$OWNER_REPO"` — parse JSON output. Set `BOOTSTRAP_COMMIT_SHA` from `bootstrap_commit_sha` and `DEFAULT_BRANCH_SET` from `default_branch_set`. Non-zero exit → surface error and stop (no cleanup).
2. Set `BOOTSTRAP_MODE=1`, `PR_NUMBER=""`, `PR_TITLE="(bootstrap initial commit)"`, `PR_URL=""`, `PR_STATE="BOOTSTRAP"`.
3. Emit `<<WORKFLOW_USER_VERIFIED: bootstrap initial commit pushed to main>>` via `skills/_shared/user-verified.md`.
4. Skip WE-4 through WE-7 (no PR to merge). Continue at WE-8 (inventory), then WE-11 (capture-env.sh with `BOOTSTRAP_MODE=1` and `BOOTSTRAP_COMMIT_SHA` exported), then WE-14 (cleanup).

### Step WE-4 — Merge decision (PR state gate + AUTO_MERGE_PR)
PR state gate (runs before AUTO_MERGE_PR; applies to both modes): `gh pr view "$PR_NUMBER" --json state --jq .state`. `MERGED` → skip to WE-6 (skip AUTO_MERGE_PR and WE-7). `CLOSED` → error "PR #<N> was closed without merging." and stop. `OPEN` → continue; output `PR #<N> is open: [<url>](<url>)`. other/error/empty → error "Unable to determine PR #<N> state." and stop.

Check `AUTO_MERGE_PR` (default `on`): `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off AUTO_MERGE_PR on && echo OFF || echo ON'`.
- `on`: announce `AUTO_MERGE_PR=on → merging now.` → WE-7.
- `off`: `AskUserQuestion` "PR #<N> — merge, wait-for-web-merge, or abort?" → WE-7 / WE-5 / stop. If `AskUserQuestion` unavailable, default to **wait-for-web-merge**.

### Step WE-5 — Web-merge wait
Display `PR #<N>: merge via GitHub UI, then reply here.` + URL; stop. On reply: `gh pr view "$PR_NUMBER" --json state` — `MERGED` → WE-6; else re-display and stop. `$PR_NUMBER` is session-local.

### Step WE-6 — Post-web-merge sync
`git fetch --prune origin`, then emit the user-verified sentinel **directly** with no preceding narrative (hook surfaces context — see `skills/_shared/user-verified.md`; description: `"User confirmed PR #<N> merged via web UI"`) → WE-8. Skip WE-7.

### Step WE-7 — Local merge
Emit the user-verified sentinel **directly** with no preceding narrative — do not restate the PR URL or describe approval in chat first. Hook (`hooks/show-user-verified-context.js`) surfaces PR URL + approval instruction above permission dialog. Use `skills/_shared/user-verified.md` (description: `"PR #<N> — approving merge to main"`), then `gh pr merge --squash --delete-branch`. On failure: surface error and stop — do NOT force-merge or bypass checks.

### Step WE-8 — Gitignored state inventory (before removing worktree)
Default backup destination: `<main_root>/.worktree-backup/<branch>/` (gitignored via `.git/info/exclude`).

**Pass 1 — dry run**: delegate inventory to `worktree-backup-worker`: `Agent({ subagent_type: "worktree-backup-worker", prompt: JSON.stringify({ mode: "dry_run", worktree_path: WORKTREE_PATH, branch: BRANCH, backup_dir: BACKUP_DIR, docker_check: true, artifact_dir: PLANS_DIR }) })`. On `status: failed`: surface summary + artifact_path and stop — do not proceed to cleanup. Otherwise: read the `summary:` line from the worker response. If the file count is 0, set `BACKUP_MANIFEST_PATH=(none)` and skip Pass 2. If the file count is 1 or more (or if the summary line cannot be parsed), proceed to Pass 2.

**Pass 2 — execute**: set `BACKUP_DIR="<main_root>/.worktree-backup/<branch>/"`; `Agent({ subagent_type: "worktree-backup-worker", prompt: JSON.stringify({ mode: "execute", worktree_path: WORKTREE_PATH, branch: BRANCH, backup_dir: BACKUP_DIR, docker_check: true, artifact_dir: PLANS_DIR }) })`. On `status: failed`: surface summary + artifact_path and stop. On `status: partial`: warn ("some files failed to copy — see artifact_path"); proceed with cleanup. On `status: copied`: worker returns `artifact_path` (manifest.json); set `BACKUP_MANIFEST_PATH="<artifact_path from worker>"`.

If no files were copied: `BACKUP_MANIFEST_PATH=(none)`. `BACKUP_DIR` may be left at default (Pass 2 skipped → directory does not exist) or explicitly set to the legacy sentinel `(none)`. `capture-env.sh` accepts both and falls back to `$PLANS_DIR/<session-id>-notes-backup/` for the WORKTREE_NOTES.md copy (issue #634). If Docker containers reference the worktree path, stop them and restart from the main path.

### Step WE-9 — Capture for Final Report (must run before WE-14 — worktree removal)
Last-chance findings review: append outstanding bugs/related/next-task findings to `<worktree>/WORKTREE_NOTES.md`. **This is the capture cutoff** — findings after WE-9 will not appear in the Final Report.

### Step WE-10 — Fallback path: issue-create promotion for unconverted WORKTREE_NOTES.md entries
For entries written via `CLAUDE.md` `## Mid-workflow finding capture` fallback. Primary path is `/issue-create` at discovery time; this step is the safety net only.
1. Skip silently when `bash "$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"` fails. List candidates: `node "$AGENTS_CONFIG_DIR/bin/worktree-notes-triage.js" list "$WORKTREE_PATH/WORKTREE_NOTES.md"`, filter to `hasMarker: false`. Empty → skip to WE-11. Non-interactive (claude -p): stderr warn `[worktree-end] WARN: N WORKTREE_NOTES entries not promoted (non-interactive)`, skip to WE-11.
2. Confirm selection via AskUserQuestion (multi-select).
3. For each selected entry (sequential): a) Invoke `/issue-create`. b) Extract issue number: `N=$(echo "$OUTPUT" | tail -n 1 | tr -d '\r' | grep -oE '[0-9]+$')`. c) Annotate: `node "$AGENTS_CONFIG_DIR/bin/worktree-notes-triage.js" annotate "$WORKTREE_PATH/WORKTREE_NOTES.md" "$LINE_NUMBER" "$N"`. d) On failure: stderr warn, skip annotate, next entry.

WE-10 must complete before WE-11 so annotations land in backup. `## History Notes` / `## Changelog Notes` are NOT triage targets.

### Step WE-11 — Env collection + JSON persist (single Bash call)
Atomicity contract enforced inside `capture-env.sh`. Do not split. session-id resolution priority: WORKTREE_NOTES.md > `$CLAUDE_SESSION_ID` > empty (→ capture-env.sh fallback retries). JSONL transcript mtime scan (resolve-session-id.sh) is FORBIDDEN here — returns wrong session after VS Code restart / context compaction (#642). `$CLAUDE_SESSION_ID` is NOT propagated to Bash subprocesses in many cases (Anthropic bug #27987); best-effort for non-Claude-Code invocations. Export PLANS_DIR; resolve SID from WORKTREE_NOTES.md Session-ID: line (awk) then fallback `$CLAUDE_SESSION_ID`. Then `bash "$AGENTS_CONFIG_DIR/skills/worktree-end/scripts/capture-env.sh" "<worktree>" "<owner>/<repo>" "<backup-dir>" "$SID"`. Output: `$PLANS_DIR/$SID-final-report-env.json`.

### Step WE-12 — Resolve main repo root
Resolve the main repo root from the worktree's `.git` file.

### Step WE-13 — Switch CWD to main worktree (before WE-14)
Releases Windows CWD lock #251; keeps `process.cwd()` healthy #268, #321. Run as its own Bash call (literal absolute path): `cd "<main-worktree-root>"`.

### Steps WE-14..WE-21 — Cleanup cascade
Canonical spec: `bash "$AGENTS_CONFIG_DIR/skills/worktree-end/scripts/cleanup-cascade.sh"`. The orchestrator issues each command separately for auditability. Only after confirmed merge success and inventory — never before.

## Rules
- **wait / abort paths: no destructive steps.** Only merge-success path (Step WE-4 → MERGED) and bootstrap-success path (Step WE-3b → bootstrap-complete.sh exit 0) run cleanup.
- `git worktree remove --force` is prohibited (see `rules/ops.md` decision path).
- Branch deletion (`git branch -D`) only in Step WE-18, allowed via inline `WORKTREE_END_SKILL=1` env prefix (enforce-worktree gates `-D` on skill authorization; non-force `-d` allowed for any branch not checked out per `git worktree list --porcelain`).
- Do not run cleanup if merge step failed or was skipped. Exception: bootstrap mode (Step WE-3b) intentionally skips merge — when `bootstrap-complete.sh` exits 0, cleanup proceeds as if merge had succeeded.
- Bootstrap mode (Step WE-3b) does not create or merge a PR. Trust the `isRemoteInPreBootstrap()` classification — only `empty-repo` activates Step WE-3b.
- Step WE-3 probe classifications other than `empty-repo` (auth / network / not-found / timeout / spawn-error / unknown) fall through to the normal push/PR flow; surfacing those errors is the push/PR flow's responsibility.
- Always propose `.worktree-backup/<branch>/` as the default backup destination.
- Always check stopped containers, not just running ones, for bind mount conflicts.
- Secret values must not appear in the backup manifest.
- Use `hooks/cleanup-orphan-dir.js` for orphan directory cleanup (WE-17) — never `rm -rf`/`Remove-Item -Recurse -Force`.
- `gh --version` must succeed before any gh command.
- `<<WORKFLOW_USER_VERIFIED: <reason>>>` is emitted in Step WE-7 (before `gh pr merge`), Step WE-6 (after `state == MERGED`), or Step WE-3b (bootstrap mode), via `skills/_shared/user-verified.md`. Never on abort or while polling.
- Step WE-2.5 honors WORKFLOW_OFF / WORKTREE_OFF session markers; skip when either is active.
- Step WE-4 PR state gate runs before the AUTO_MERGE_PR check; applies to both on/off modes; `MERGED` always routes to Step WE-6.
- `AUTO_MERGE_PR=on` skips `AskUserQuestion` in Step WE-4 (worktree mode only).
- `$PR_NUMBER` captured in Step WE-3; used explicitly in Step WE-5. Session-local only.
- This skill does NOT modify `workflow-gate.js`.
- Step WE-9..WE-11 invariants: see `skills/worktree-end/scripts/capture-env.sh` header (atomicity / BRANCH_DELETED omission / four restart categories).
- Step WE-11 MUST execute as one Bash tool call (survives Windows env reset, #504). Do not split into separate calls.
- Step WE-11 JSON output MUST NOT include `BRANCH_DELETED` (accuracy fix tracked separately; renderer renders `(none)` as fail-safe, #504).
- Step WE-11 JSON output MUST include all four post-merge action categories (cc_restart / vscode_reload / installer_rerun / os_reboot). CLAUDE_CODE_RESTART_REQUIRED is kept as deprecated alias for backward compat.
- Step WE-20 writes `WORKTREE_NOTES.md`; the env JSON at `$PLANS_DIR/<session-id>-final-report-env.json` is consumed by `/session-close` Step 4.
- `/session-close` Step 4 reads env JSON + outcome JSON + intent.md + WORKTREE_NOTES.md backup; LLM substitutes placeholders and emits Final Report verbatim into assistant text; then runs `echo "<<WORKFLOW_MARK_STEP_final_report_complete>>"`.
- `stop-final-report-guard.js` validates all 10 headings from `getSectionHeadings()` appear after `## Final Report — <sid>` in transcript (no `reported` flag check).
- Do not reformat, summarize, reorder, or merge any Final Report section.
- Do not delete, transform, summarize, or reorder any heading (`## Final Report` or `### ...`) in the Final Report.
- Do not reformat Final Report section content into prose (e.g., writing `Closed Issues: #N` instead of the `### Closed Issues` heading followed by `- #N`).
- JSONL transcript mtime scan (`bin/lib/resolve-session-id.sh`) must NOT be used in the worktree-end session-id resolution path — it picks the most-recently-touched session which may differ from the session that created the worktree (#642).
