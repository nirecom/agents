# GitHub Issues Workflow

## Notation

GitHub Issues and PRs share the same number space. Distinguish them in prose:

- **Issues**: `#N` (no prefix)
- **Pull requests**: `PR #N`

## Session model

- Relation: 1 session = N issues (N ≥ 1) = N `history.md` entries = 1 PR.
- `closes_issues` source: `${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/<session-id>-intent.md` (canonical parser: `hooks/lib/parse-closes-issues.js` — do not reimplement).
- `closes_issues` order: insertion order. All entries are semantically symmetric.

## Active task list

- GitHub Issues is the single source of truth for active tasks.
- `docs/todo.md` is a pointer only — no per-task entries kept locally.
- List open: `gh issue list --state open` or `gh issue view <N>`.

## Labels

| Label | Meaning |
|---|---|
| `type:task` | Normal task. Closed → FEATURE entry in `history.md`. |
| `type:incident` | Incident. Closed → INCIDENT entry in `history.md`. |
| `status:cancelled` | Cancelled without completion. Applied before close by `/issue-close-migrated`. |
| `status:migrated` | Merged into another issue. Applied before close by `/issue-close-migrated`. |
| `meta` | Planning/architecture issue with no implementation. Close via `admin_close_path`. Convention: `Group: ` title prefix. Sub-issues carry the actual work. |

- Apply labels: `bin/github-issues/sync-labels.sh` (reads `.github/labels.yml`, runs `gh label create --force`).

## Issue creation

`/issue-create` surveys existing issues, then dispatches one of five verdicts:

| Verdict | Action |
|---|---|
| `none` | Create a new standalone issue |
| `reopen` | Reopen an existing duplicate (with user confirmation) |
| `sub-of` | Create the new issue and attach it under an existing parent |
| `make-parent` | Create the new issue as parent of existing siblings (user confirmation) |
| `sibling` | Create the new issue with `Related to #N` cross-reference in body |

- Enforce `type:task`; attach to Projects v2 automatically.
- Incident issues: `gh issue create --label "type:incident"` directly (do not use this skill).
- Non-GitHub remotes: skip the survey phase.
- Projects v2 attach failure is non-fatal: issue created regardless; re-run `gh project item-add 1 --owner nirecom --url <issue-url>` to recover.

## meta label and admin_close_path

- Title convention: `Group: ` prefix (apply by hand; not code-enforced).
- Close route: `admin_close_path` when OPEN + all sub-issues closed — no Phase 1 sentinel, no PR, no worktree required.
- G.5 cascade: auto-accepts meta parents (code-based; no `AskUserQuestion`).
- `historyEntry` in outcome JSON: `"skipped_admin_close"`.
- Body: do NOT carry sub-issue completion state (checkboxes, status columns). SSOT is each sub-issue's own state via GitHub's native sub-issue progress UI.

## Close path

- **Phase 1 (`/issue-close-stage`)**: run from linked worktree before PR merge — sub-issue gate, pending→appended sentinel, parent body update.
- **Phase 2 (`/issue-close-finalize`)**: run from main worktree after PR merge — parent update (Step G), close (Step H), resolved-by + appended sentinels (Step J), WIP clear (Step K).
- Merge SHA: resolved via `find-pr-by-marker.sh` using `<!-- issue-close-pr-of: <N> -->` marker added by `/commit-push`.
- `docs/history.md`: written by `/worktree-end` Step WE-21 from `WORKTREE_NOTES.md` bullets. `issue-to-history.sh` retained for `/issue-reconcile` and out-of-band repair only.

**Flow 1 — standard (Phase 1 then Phase 2):**
1. Run `/issue-close-stage <N>` from linked worktree (WF-CODE-9), before `/commit-push`.
2. Run `/commit-push` (pre-flights Phase 1 via `check-phase1-complete.sh`; appends `<!-- issue-close-pr-of: <N> -->` to PR body).
3. After PR merge: run `/issue-close-finalize --from-session` from main worktree.

**Flow 2 — `closes #N` auto-close (no Phase 1 ran):**
- Triage detects `CLOSED + (none)` → `auto_close_path`: parent update → resolved-by/sentinel comments → WIP clear.
- `docs/history.md` not written (`historyEntry=skipped_no_history_notes`). Use `/issue-reconcile` for backfill.

- `enforce-issue-close.js`: blocks bare `gh issue close` from the Bash tool; error message points at `/issue-close-finalize`.
- Out-of-band closes (web UI, mobile, scripts): bypass the hook — use `/issue-reconcile` for backfill.

## Sub-issues

- Use `gh api` directly (`gh` CLI lacks sub-issue support — cli/cli#10298).
- Attach: `POST /repos/{owner}/{repo}/issues/{N}/sub_issues` — `sub_issue_id` must be the child's integer databaseId (not issue number, not GraphQL node id).
- Fetch databaseId: `gh api graphql -f query='{ repository(owner: "OWNER", name: "REPO") { issue(number: N) { databaseId } } }' --jq '.data.repository.issue.databaseId'`
- Path param `{N}`: parent issue number. Pass `sub_issue_id` via `-F` (typed integer), not `-f` (string) — API returns HTTP 422 for string.
- Close gate (Step B): any child in `open` state blocks closing the parent. Cancelled/migrated children must be closed first (label alone is not enough).

<!-- dual-write period ended; docs/todo.md is now a pointer only (migrated 2026-05-14, issue #222). -->

## Environment

- `gh` must have `project` scope for Projects v2 (`/issue-create`): `gh auth refresh -s project`. Default `gh auth login` does not include `project`.
- `AGENTS_CONFIG_DIR` must be set for `/issue-close-stage` and `/issue-close-finalize` (skills abort with clear error if unset).
- `gh issue close` from bash scripts (`close-completed.sh`, `close-not-planned.sh`) is invisible to `enforce-issue-close.js` — PreToolUse fires on the Bash-tool command head only, not subprocesses.
- `ISSUE_CLOSE_SKILL=1` is effective only in the hook's Node.js process (set at session launch). Bash-tool inline or `export` forms do not reach the hook process.
- `history.md` entries: English regardless of repo visibility (see `rules/language.md`). Issue body language is author's choice.
