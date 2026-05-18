# GitHub Issues Workflow

## Notation

GitHub Issues and PRs share the same number space. Always distinguish them in prose:

- **Issues**: `#N` (no prefix)
- **Pull requests**: `PR #N`

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

Apply labels with `bin/github-issues/sync-labels.sh` (reads `.github/labels.yml`,
runs `gh label create --force`).

## Issue creation

Use `/issue-create` to create task issues from a Claude Code session. The skill
automatically surveys existing issues for duplicates, parents, and siblings before
creating a new one — so duplicate/parent/sibling detection is handled; no manual
prompt needed. The survey drives one of five verdicts:

| Verdict | Action |
|---|---|
| `none` | Create a new standalone issue |
| `reopen` | Reopen an existing duplicate (with user confirmation) |
| `sub-of` | Create the new issue and attach it under an existing parent |
| `make-parent` | Create the new issue as parent of existing siblings (user confirmation) |
| `sibling` | Create the new issue with `Related to #N` cross-reference in body |

The skill enforces `type:task` and attaches the new issue to Projects v2 automatically.
For incident issues, use the `.github/ISSUE_TEMPLATE/incident.yml` web UI template
or `gh issue create --label "type:incident"` directly. Non-GitHub remotes skip the
survey phase.

    /issue-create --title "<title>" --body "<body>" [--label ... --assignee ... --milestone ...]

Projects v2 attach failure is non-fatal: the issue is created regardless, and a
warning is printed. Re-run `gh project item-add 1 --owner nirecom --url <issue-url>`
manually if recovery is needed.

## Close path

The close flow is split into two phases to avoid main-worktree writes to
`docs/history.md`:

- **Phase 1 — `/issue-close-stage <N>`** runs from the linked worktree BEFORE
  the PR is merged. It performs the sub-issue gate, posts the pending sentinel,
  commits the `docs/history.md` entry on the feature branch, promotes the
  sentinel to `appended`, and updates the parent body if applicable.
- **Phase 2 — `/issue-close-finalize <N>`** runs from the main worktree AFTER
  the PR is merged. It is API-only on the normal path: it closes the issue and
  posts the resolved-by + final `appended` sentinel. The merge SHA is resolved
  via `find-pr-by-marker.sh` using the `<!-- issue-close-pr-of: <N> -->` marker
  that `/commit-push` adds to the PR body.

**Flow 1 — standard workflow (Phase 1 then Phase 2):**

1. Inside the linked worktree, after staging tests/code/docs and before
   `/commit-push`, run `/issue-close-stage <N>` (Step 8.5 of the workflow).
2. Run `/commit-push`. It pre-flights Phase 1 completion via
   `check-phase1-complete.sh` (sentinel + committed history entry) and appends
   `<!-- issue-close-pr-of: <N> -->` to the PR body.
3. After the PR is merged, run `/issue-close-finalize --from-session` from the
   main worktree.

**Flow 2 — `closes #N` auto-close path (no Phase 1 ever ran):**

When the PR uses GitHub's `closes #N` keyword and the issue gets auto-closed
without `/issue-close-stage` having run, `/issue-close-finalize`'s triage
detects `CLOSED + (none)` and routes to the `auto_close_path` action:
sub-issue gate → doc-append → parent update → resolved-by/sentinel comments.
**Existing limit:** Step E (doc-append) writes to `docs/history.md` from the
main worktree and is blocked under `ENFORCE_WORKTREE=on`; tracked separately.

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
child's **GraphQL node id** in `sub_issue_id`, not the issue number. Use
`gh issue view <N> --json id --jq .id` to fetch it (`.id` returns the node id,
e.g. `I_kwDO...`). The path parameter `{N}` is the parent's issue number (integer).

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
  clear error if unset). Consumer repos (dotfiles, dotfiles-private) inherit
  the same variable.
- `ISSUE_CLOSE_SKILL=1` is set by both skills while running their own
  `gh issue close` / `gh issue comment` invocations to bypass the
  `enforce-issue-close.js` hook. Do not set this anywhere else.
- `history.md` entries are written in English regardless of repo visibility
  (`rules/language.md`). The issue body language is the author's choice.
