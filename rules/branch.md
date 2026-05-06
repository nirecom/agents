# Feature Branch Operations

When `ENFORCE_WORKTREE=on` (default): always work from a **linked worktree** on a feature branch.
The `enforce-worktree` (PreToolUse) and `pre-commit` hooks block edits and commits from the
main checkout and on the default branch.

For parallel sessions, use `/worktree-start` to create the worktree — see `worktree.md`.

> **Note:** `ENFORCE_WORKTREE=on` blocks all writes from the **main checkout** regardless of
> which branch is checked out there. A feature branch alone does not satisfy the guard —
> you must work from a **linked worktree** (via `/worktree-start`) or set `ENFORCE_WORKTREE=off`.

## How to Start

```
git switch -c <branch>
```

Branch names must be ASCII (`[a-zA-Z0-9]` + `-`, `_`, `/`) — see `language.md`.

## How to Finish

- **PR flow (standard):** push → `gh pr create` → merge via `/commit-push` or `/worktree-end`.

No dedicated `branch-start` / `branch-end` skills — `/commit-push` and `/worktree-end` are sufficient.

## When `ENFORCE_WORKTREE=off` (opt-out)

For genuinely trivial changes (one-line typo, lockfile-only update), set
`ENFORCE_WORKTREE=off` in `.env` to disable the guard. Then the table below
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
Work directly on main for these (with `ENFORCE_WORKTREE=off`).
