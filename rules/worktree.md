# Worktree Operations

When starting or ending a worktree operation, always use the following skills —
do not call `git worktree add` / `git worktree remove` directly:

- Start: `/worktree-start`
- End (merge + cleanup): `/worktree-end`

With `ENFORCE_WORKTREE=on` (default): the main worktree is reserved for merge/pull only.
All writes must happen from a linked worktree. Use `/worktree-start` to create one.
With `ENFORCE_WORKTREE=off`: direct main work is allowed (trivial changes only).
Set this in agents config (`.env`) when the isolation cost exceeds the benefit.

See `branch.md` for branch naming and the standard branch flow.
See `docs/parallel-sessions.md` for the full lifecycle guide.

## Standard Path

Worktrees follow a two-level layout: `<WORKTREE_BASE_DIR>/<task-name>/<repo-name>`.

- **WORKTREE_BASE_DIR** defaults to `~/git/worktrees`.
  Set it in your agents config (`.env`) to customize:
  ```
  # Windows example
  WORKTREE_BASE_DIR=C:\git\worktrees
  # POSIX example
  WORKTREE_BASE_DIR=/home/user/worktrees
  ```
- **task-name**: short identifier for the work (`[a-zA-Z0-9_-]+`), shared across repos.
- **repo-name**: the repository name (e.g. `agents`, `dotfiles`).

Example with two repos in the same task:
```
C:\git\worktrees\
  my-feature\
    agents\          ← git worktree for agents repo
    dotfiles\        ← git worktree for dotfiles repo (if needed)
```
