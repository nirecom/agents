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

## Session-scoped escape hatch

For maintenance or recovery work that must happen from the main worktree within
a single session (e.g. `/worktree-end` × Windows CWD-lock recovery), use the
session-scoped sentinel instead of editing `.env` globally:

    echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: <reason>>>"

Attach `: <reason>` (bare form emits a warning). This writes a per-session
marker file so that only the current session treats `ENFORCE_WORKTREE` as off.
All other concurrent Claude Code sessions remain at `on`.

To restore enforcement within the same session, emit the matching sentinel:

    echo "<<WORKFLOW_ENFORCE_WORKTREE_ON: <reason>>>"

The hook layer resolves the session ID (Anthropic bug #27987 prevents
`$CLAUDE_SESSION_ID` from being propagated to Bash subprocesses) and deletes
the marker keyed to the current session. The operation is idempotent — if no
marker exists, it is a silent no-op. Enforcement also restores automatically
in the next session, since the marker is keyed on the current session ID.

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
