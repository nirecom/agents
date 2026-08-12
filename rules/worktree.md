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

## Session-scoped escape hatch (WORKTREE_OFF)

Session-scoped escape hatch that treats `ENFORCE_WORKTREE` as off for the current Claude Code session, without editing `.env` globally.

### Sentinels

| Sentinel | Permission | Effect |
|---|---|---|
| `<<WORKFLOW_ENFORCE_WORKTREE_OFF: {reason}>>` | **ask** (requires user approval) | Creates `${sid}.worktree-off` marker; main-worktree writes allowed |
| `<<WORKFLOW_ENFORCE_WORKTREE_ON: {reason}>>` | **allow** (auto-approved) | Removes marker; enforcement restored |

The `{reason}` field is mandatory and non-empty (bare form emits a warning).

### What is bypassed

Only `enforce-worktree.js`. Every other hook — credentials, outbound scan, system ops, workflow gate — stays active.
Inclusion criterion and the full honoring-hooks table: SSOT is `docs/architecture/claude-code/marker-bypass-contract.md`.
WORKFLOW_OFF subsumes this marker; emitting both is redundant — see `rules/workflow-off.md`.

### When to use

Appropriate for: maintenance or recovery work that must run from the main worktree in one session (e.g. `/worktree-end` × Windows CWD-lock recovery).
Do NOT use for: ordinary feature work that belongs in a linked worktree, or to unblock a single hook-blocked command.

### Sanctioned-command false-block recovery

SSOT: the same-named section in `rules/workflow-off.md`.

### Restoring enforcement

Emit the `_ON` sentinel (auto-allowed). The hook layer resolves the session ID (Anthropic bug #27987 prevents `$CLAUDE_SESSION_ID` from reaching Bash subprocesses) and deletes the marker keyed to the current session; deleting a marker that does not exist is a silent no-op.
Enforcement also restores automatically in the next session, since the marker is keyed on the current session ID.

### Scope

Session-scoped: only the current session is affected; all other concurrent Claude Code sessions remain at `on`.

## Standard Path

Worktrees follow a two-level layout: `<WORKTREE_BASE_DIR>/<task-name>/<repo-name>`.

- **WORKTREE_BASE_DIR** defaults to `~/git/worktrees`. Set it in your agents config (`.env`) to customize (e.g. `WORKTREE_BASE_DIR=C:\git\worktrees` on Windows, `WORKTREE_BASE_DIR=/home/<user>/worktrees` on POSIX).
- **task-name**: short identifier for the work (`[a-zA-Z0-9][a-zA-Z0-9_-]*`), shared across repos.
- **repo-name**: the repository name (e.g. `agents`, `dotfiles`).

Worktrees use a two-level path: `<WORKTREE_BASE_DIR>/<task-name>/<repo-name>`. Example: a task `my-feature` in two repos uses `worktrees/my-feature/agents/` and `worktrees/my-feature/dotfiles/`.
