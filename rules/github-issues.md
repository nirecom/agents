# GitHub Issues Workflow

## todo.md as ID index

After migration, `docs/todo.md` is a thin index over GitHub Issues:

```
- [ ] #42 Short title
- [ ] #43 Another title
```

Open the issue (`gh issue view <N>`) for full context. Close via `/issue-close <N>`
— the line is removed from `todo.md` automatically.

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

Inside a Claude Code session, `/issue-close <N>` is the **only sanctioned path**.
- It runs the transaction-safe steps in `skills/issue-close/SKILL.md`:
  state check → sub-issue gate → sentinel comment → doc-append → close → todo.md edit.
- The `enforce-issue-close.js` PreToolUse hook blocks bare `gh issue close` from
  the Bash tool, suggesting `/issue-close` instead.

**Out-of-band closes** (web UI, mobile, another shell, scripts) bypass this hook —
the guard is best-effort, scoped to Claude Code's Bash tool. Recover with
`/issue-reconcile`: it scans closed issues whose comments lack the
`<!-- issue-close-sentinel: appended -->` marker and prompts to backfill
`history.md`.

## Sub-issues

Use GitHub Sub-issues for phase/parallel breakdowns. The official `gh` CLI does
not yet support sub-issues (cli/cli#10298), so the skill uses `gh api` directly.

Key fact: `POST /repos/{owner}/{repo}/issues/{N}/sub_issues` expects the
**database id** (integer) in `sub_issue_id`, not the issue number. Use
`gh issue view <N> --json id --jq .id` to fetch it.

The close path's Step B gates the parent: if any child issue is in state `open`,
closing the parent is blocked. Cancelled/migrated children must already be closed
(label alone is not enough).

## dual-write period (~1 month from Phase 3 start)

During dual-write:
- New tasks: create the issue first, then append `- [ ] #N <title>` to `todo.md`.
- Completion: `/issue-close <N>` removes the line and writes `history.md`.
- Weekly: run `/issue-reconcile` to backfill any UI/mobile closes.

End conditions (all of):
1. ≥ 4 weeks since Phase 3 start.
2. ≥ 5 successful `/issue-close` invocations with clean `history.md` entries.
3. `gh issue list --state open` count matches `todo.md` line count, sustained
   for ≥ 1 week.

Decommission: shrink `todo.md` to a pointer at the GitHub Issues list and drop
the workflow's references to it.

## Environment

- `AGENTS_CONFIG_DIR` must be set in every session that uses `/issue-close`
  (the skill aborts with a clear error if unset). Consumer repos (dotfiles,
  dotfiles-private) inherit the same variable.
- `ISSUE_CLOSE_SKILL=1` is set by the skill while running its own
  `gh issue close` / `gh issue comment` invocations to bypass the
  `enforce-issue-close.js` hook. Do not set this anywhere else.
- `history.md` entries are written in English regardless of repo visibility
  (`rules/language.md`). The issue body language is the author's choice.
