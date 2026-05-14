# GitHub Issues Workflow

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

## Close path

**Flow 1 — PR-based close (`closes #N` in PR description):**

1. When creating the PR, include `Closes #<N>` in `--body`. GitHub auto-closes
   the issue on merge.
2. After the PR is merged, run `/issue-close <N>`. The skill's triage script
   detects `CLOSED + (none)` and routes to the `auto_close_path` action:
   sub-issue gate → doc-append → parent update → resolved-by/sentinel comments.
   No manual `gh issue close` needed.

**Flow 2 — session-based close (no PR, or issue closed mid-session):**

Inside a Claude Code session, `/issue-close <N>` is the **only sanctioned path**.
The triage script encodes all state-to-step routing; each step is idempotent.
The `enforce-issue-close.js` PreToolUse hook blocks bare `gh issue close` from
the Bash tool, suggesting `/issue-close` instead.

**Out-of-band closes** (web UI, mobile, another shell, scripts) bypass this hook —
the guard is best-effort, scoped to Claude Code's Bash tool. `closes #N`
auto-closes are handled by `/issue-close` directly via the `auto_close_path`
action. For other out-of-band closes (where `/issue-close` was never run), use
`/issue-reconcile` to scan closed issues whose comments lack the
`<!-- issue-close-sentinel: appended -->` marker and backfill `history.md`.

## Sub-issues

Use GitHub Sub-issues for phase/parallel breakdowns. The official `gh` CLI does
not yet support sub-issues (cli/cli#10298), so the skill uses `gh api` directly.

Key fact: `POST /repos/{owner}/{repo}/issues/{N}/sub_issues` expects the
**database id** (integer) in `sub_issue_id`, not the issue number. Use
`gh issue view <N> --json id --jq .id` to fetch it.

The close path's Step B gates the parent: if any child issue is in state `open`,
closing the parent is blocked. Cancelled/migrated children must already be closed
(label alone is not enough).

<!-- dual-write period ended; docs/todo.md is now a pointer only (migrated 2026-05-14, issue #222). -->

## Environment

- `AGENTS_CONFIG_DIR` must be set in every session that uses `/issue-close`
  (the skill aborts with a clear error if unset). Consumer repos (dotfiles,
  dotfiles-private) inherit the same variable.
- `ISSUE_CLOSE_SKILL=1` is set by the skill while running its own
  `gh issue close` / `gh issue comment` invocations to bypass the
  `enforce-issue-close.js` hook. Do not set this anywhere else.
- `history.md` entries are written in English regardless of repo visibility
  (`rules/language.md`). The issue body language is the author's choice.
