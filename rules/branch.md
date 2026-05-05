# Feature Branch Operations

When `AGENT_AUTO_BRANCH=on` (default): always work on a feature branch.
The `auto-branch-guard` (PreToolUse) and `pre-commit` hooks block edits and
commits on the default branch.

This file covers naming and the start/finish flow. For when a worktree is
additionally needed (escalation), see `worktree.md`.

## How to Start

```
git switch -c <branch>
```

Branch names must be ASCII (`[a-zA-Z0-9]` + `-`, `_`, `/`) — see `language.md`.

## Need More Isolation? (escalation to worktree)

If the work additionally requires parallel sessions, an isolated runtime (Docker / DB / long-running
process), or large amounts of gitignored state, escalate to a worktree — see `worktree.md`.

## How to Finish

- **PR flow:** `gh pr create` → merge via GitHub UI or `/commit-push`
- **Local merge:** `git switch main && git merge --ff-only <branch> && git branch -d <branch>`

No dedicated `branch-start` / `branch-end` skills — `/commit-push` and plain git are sufficient.

## When `AGENT_AUTO_BRANCH=off` (opt-out)

For genuinely trivial changes (one-line typo, lockfile-only update), set
`AGENT_AUTO_BRANCH=off` in `.env` to disable the guard. Then the table below
applies for the branch-vs-main decision. Re-enable after.

| Scene | Reason |
|---|---|
| Multi-commit change meant to land as a single unit | Can be reviewed or reverted atomically |
| Keeping main green (CI / build) while work is in progress | Intermediate states never touch main |
| High-risk changes (refactors, dependency upgrades, build config, installer changes) | main stays at a known-good state |
| Experimental work that may be abandoned mid-way | Branch can simply be deleted |
| Collaborative work requiring pre-merge review | Standard PR review flow |

**Not a fit (off-mode):** single-commit typo / doc fixes, small already-verified config tweaks,
trivial dependency additions (lock-file-only update), investigation commits under 30 minutes.
Work directly on main for these.
