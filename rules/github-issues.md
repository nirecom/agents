# GitHub Issues Workflow

## Notation

GitHub Issues and PRs share the same number space. Always distinguish them in prose:

- **Issues**: `#N` (no prefix)
- **Pull requests**: `PR #N`

## Session model: N issues per session

A workflow session may track one or more issues. The canonical relation is:

    1 session = N issues (N >= 1) = N history.md entries (one per issue) = 1 PR

The session's `closes_issues` list lives in
`${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/<session-id>-intent.md`
(canonical parser: `hooks/lib/parse-closes-issues.js`).

### Terminology

- **primary** — the first entry of `closes_issues`. Exactly one primary per
  session. Represents the session in single-issue contexts (Projects v2 card,
  the `## Issue` anchor in `intent.md`).
- **related** — every non-primary entry of `closes_issues`. Each related issue
  is a full first-class member (own `history.md` entry, own `Closes #<N>`
  line, own close-pr-of marker, own WIP fingerprint) but does not represent
  the session in single-issue contexts.

### Primary confirmation (single-window invariant)

When N first crosses from 1 to >=2 within a session, exactly one
AskUserQuestion confirms which issue is the primary. The confirmation fires at
the earliest of:
- `workflow-init` Step 1 (b) — when 2+ `#N` are present in the initial user
  prompt; OR
- `clarify-intent` Completion — when the interview produces 2+ entries in
  `closes_issues` (Path C / interview-emerged multi-N).

The two triggers are mutually exclusive. Procedure details live in the
respective SKILL.md files.

## Active task list

GitHub Issues is the single source of truth for active tasks. `docs/todo.md` is
a pointer to the GitHub Issues list — no per-task entries are kept locally.
Open issues with `gh issue list --state open` or `gh issue view <N>`.

## Labels

| Label | Meaning |
|---|---|
| `type:task` | Normal task. Closed → FEATURE entry in `history.md`. |
| `type:incident` | Incident. Closed → INCIDENT entry in `history.md`. |
| `status:cancelled` | Cancelled without completion. Set after close. |
| `status:migrated` | Merged into another issue. Set after close. |
| `meta` | Planning/architecture issue with no implementation. Close via `admin_close_path`. Convention: `Group: ` title prefix. Sub-issues carry the actual work. |

Apply labels with `bin/github-issues/sync-labels.sh` (reads `.github/labels.yml`,
runs `gh label create --force`).

## Issue creation

`/issue-create` surveys existing issues, then dispatches one of five verdicts:

| Verdict | Action |
|---|---|
| `none` | Create a new standalone issue |
| `reopen` | Reopen an existing duplicate (with user confirmation) |
| `sub-of` | Create the new issue and attach it under an existing parent |
| `make-parent` | Create the new issue as parent of existing siblings (user confirmation) |
| `sibling` | Create the new issue with `Related to #N` cross-reference in body |

- `type:task` is enforced; the issue is attached to Projects v2 automatically.
- Incident issues: use `.github/ISSUE_TEMPLATE/incident.yml` or `gh issue create --label "type:incident"` directly.
- Non-GitHub remotes skip the survey phase.

    /issue-create --title "<title>" --body "<body>" [--label ... --assignee ... --milestone ...]

Projects v2 attach failure is non-fatal: the issue is created regardless, and a
warning is printed. Re-run `gh project item-add 1 --owner nirecom --url <issue-url>`
manually if recovery is needed.

## meta label and admin_close_path

Issues with the `meta` label use a special close path:
- Title convention: `Group: ` prefix (not enforced in code; apply by hand when creating).
- `/issue-close-finalize` routes them via `admin_close_path` when OPEN + all sub-issues closed — no Phase 1 sentinel, no PR, no worktree required.
- G.5 parent-close cascade auto-accepts meta parents (code-based; no AskUserQuestion).
- `historyEntry` in outcome JSON: `"skipped_admin_close"` (distinct from `auto_close_path`'s `"skipped_no_history_notes"`).

## Close path

The close flow is split into two phases:

- **Phase 1 — `/issue-close-stage <N>`** runs from the linked worktree BEFORE
  the PR is merged. It performs the sub-issue gate, posts the pending sentinel,
  promotes the sentinel to `appended`, and updates the parent body if applicable.
- **Phase 2 — `/issue-close-finalize <N>`** runs from the main worktree AFTER
  the PR is merged. It updates the parent body (Step G), closes the issue
  (Step H), and posts the resolved-by + appended sentinels (Step J), then
  clears WIP state (Step K). The merge SHA is resolved via
  `find-pr-by-marker.sh` using the `<!-- issue-close-pr-of: <N> -->` marker that
  `/commit-push` adds to the PR body.
- **`docs/history.md` is written by `/worktree-end` Step 6h** before Phase 2
  runs (Approach C, #690). Step 6h is the single canonical writer of both
  `docs/history.md` and `CHANGELOG.md` from `WORKTREE_NOTES.md ## History Notes`
  / `## Changelog Notes` bullets. The previous Phase 2 Step E (`docs/history.md`
  write via `issue-to-history.sh`) was removed. `issue-to-history.sh` is
  retained as a standalone tool for `/issue-reconcile` and out-of-band repair.

**Flow 1 — standard workflow (Phase 1 then Phase 2):**

1. Inside the linked worktree, after staging tests/code/docs and before
   `/commit-push`, run `/issue-close-stage <N>` (Step 8.5 of the workflow).
2. Run `/commit-push`. It pre-flights Phase 1 completion via
   `check-phase1-complete.sh` (sentinel-only) and appends
   `<!-- issue-close-pr-of: <N> -->` to the PR body.
3. After the PR is merged, run `/issue-close-finalize --from-session` from the
   main worktree.

**Flow 2 — `closes #N` auto-close path (no Phase 1 ever ran):**

When the PR uses GitHub's `closes #N` keyword and the issue gets auto-closed
without `/issue-close-stage` having run, `/issue-close-finalize`'s triage
detects `CLOSED + (none)` and routes to the `auto_close_path` action:
parent update → resolved-by/sentinel comments → WIP clear. `docs/history.md`
is NOT written on this path (no WORKTREE_NOTES.md available — the outcome
JSON records `historyEntry=skipped_no_history_notes`). For backfill, use
`/issue-reconcile`.

**Hook surface:** the `enforce-issue-close.js` PreToolUse hook blocks bare
`gh issue close` from the Bash tool. The error message points at
`/issue-close-finalize` (and reminds about `/issue-close-stage` for Phase 1).

**Out-of-band closes** (web UI, mobile, another shell, scripts) bypass this
hook — the guard is best-effort, scoped to Claude Code's Bash tool. For closes
where neither `/issue-close-stage` nor `/issue-close-finalize` ever ran, use
`/issue-reconcile` to scan closed issues whose comments lack the
`<!-- issue-close-sentinel: appended -->` marker and backfill `history.md`.

## Sub-issues

Use GitHub Sub-issues for phase/parallel breakdowns. The official `gh` CLI does
not yet support sub-issues (cli/cli#10298), so the skill uses `gh api` directly.

Key fact: `POST /repos/{owner}/{repo}/issues/{N}/sub_issues` expects the
child's **integer databaseId** in `sub_issue_id`, not the issue number and
not the GraphQL node id. Use
`gh api graphql -f query='{ repository(owner: "OWNER", name: "REPO") { issue(number: N) { databaseId } } }' --jq '.data.repository.issue.databaseId'`
to fetch it (an integer such as `2851234567`). The path parameter `{N}` is the parent's issue number
(integer). Pass it via `gh api -F` (typed integer), not `-f` (string) — the
API returns HTTP 422 for string values.

The close path's Step B gates the parent: if any child issue is in state `open`,
closing the parent is blocked. Cancelled/migrated children must already be closed
(label alone is not enough).

<!-- dual-write period ended; docs/todo.md is now a pointer only (migrated 2026-05-14, issue #222). -->

## Environment

- `gh` CLI must be authenticated with the `project` scope for Projects v2
  operations (used by `/issue-create`). Add with
  `gh auth refresh -s project` (browser-based OAuth). Default `gh auth login`
  scopes do NOT include `project`. Audit of which repo owns gh install + scope
  setup is tracked in #295.
- `AGENTS_CONFIG_DIR` must be set in every session that uses
  `/issue-close-stage` or `/issue-close-finalize` (the skills abort with a
  clear error if unset). Consumer repos (dotfiles, my-private-repo) inherit
  the same variable.
- `ISSUE_CLOSE_SKILL=1` is set by both skills as an inline env prefix to
  bypass `enforce-issue-close.js` for `gh issue close` / `gh issue comment`
  calls. The Phase 2 Step E `enforce-worktree.js` bypass for
  `git add docs/history.md` was removed in #690 (Step E itself was removed —
  Step 6h of `/worktree-end` is now the canonical history writer). Do not set
  it elsewhere.
- `history.md` entries are written in English regardless of repo visibility
  (`rules/language.md`). The issue body language is the author's choice.
