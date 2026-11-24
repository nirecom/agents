---
paths:
  - ".on-demand-only/never-match"
---
<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->

# Worktree Operations

When starting or ending a worktree operation, always use the following skills —
do not call `git worktree add` / `git worktree remove` directly:

- Start: `/worktree-start`
- End (merge + cleanup): `/worktree-end`

With `ENFORCE_WORKTREE=on` (default): the main worktree is reserved for merge/pull only.
All writes must happen from a linked worktree. Use `/worktree-start` to create one.
With `ENFORCE_WORKTREE=off`: direct main work is allowed (trivial changes only).
Set this in agents config (`.env`) when the isolation cost exceeds the benefit.
To lift enforcement for one session instead of globally, run `/enforce-workflow-off`.

When the main worktree branch has diverged from its remote (ahead AND behind), recover per `rules/ops.md` "Diverged Main Worktree Recovery".

See `branch.md` for branch naming and the standard branch flow.
See `docs/parallel-sessions.md` for the full lifecycle guide.

## Standard Path

Worktrees follow a two-level layout: `<base>/<task-name>/<repo-name>`.

- **base**: unset `WORKTREE_BASE_DIR` → each repo's own `<repo>/.claude/worktrees`; set it in agents config (`.env`) for one base shared by every repo. `bin/worktree-base` owns the resolution — never rebuild the path by hand.
- **task-name**: short identifier for the work (`[a-zA-Z0-9][a-zA-Z0-9_-]*`), shared across repos.
- **repo-name**: the repository name (e.g. `agents`, `dotfiles`).

Example: a task `my-feature` in `agents` uses `agents/.claude/worktrees/my-feature/agents/` by default.
