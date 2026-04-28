# Worktree Operations

When starting or ending a worktree operation, always use the following skills —
do not call `git worktree add` / `git worktree remove` directly:

- Start: `/worktree-start`
- End (merge + cleanup): `/worktree-end`

## When to Use a Worktree

| Scene | Reason |
|---|---|
| Parallel sessions (multiple features developed concurrently) | Each worktree is an independent checkout |
| Developing a new feature without stopping main's running service (Docker / DB / long-running process) | Main's working tree is unchanged |
| Long-running feature branches (many commits + milestones) | No need to switch main's checkout |
| Work that generates large amounts of gitignored state (.env switches, new data/, separate venv, etc.) | Main's state is not affected |
| High-risk refactor where main should be kept as a known-good rollback target | Main remains reachable at any time |

**Not a fit:** single-file edits, typos, docs changes, read-only investigation, tasks under
30 minutes (isolation cost > benefit). Work directly on main for these.
