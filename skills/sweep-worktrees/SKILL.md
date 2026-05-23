---
name: sweep-worktrees
description: Reclaims zombie linked worktrees (and their branches/markers) that /worktree-end could not remove due to Windows CWD lock or similar.
user-invocable: true
model: sonnet
---

Reclaims zombie linked worktrees left behind when `/worktree-end` could not
physically remove a worktree (e.g. Windows CWD lock from VS Code's extension
host). After successful worktree removal, also deletes the corresponding
branch and any `pending-branch-delete-` marker.

## Procedure

1. Resolve `$AGENTS_CONFIG_DIR` from the environment; abort with a clear error
   if unset.
2. Invoke the sweeper script (no `--apply` = dry-run):
   ```
   bash "$AGENTS_CONFIG_DIR/bin/sweep-worktrees.sh" [--apply] [--min-age-hours N] [--ci-mode]
   ```
3. Print the script's stdout verbatim. Do not summarize or filter.

Forward the user's flags verbatim. Add no flags of your own.

## Rules

- Default is dry-run; `--apply` must be explicit to delete.
- `--force` is not supported; the script uses `git worktree remove` without `--force`.
- EPERM / busy / not-empty failures on a per-worktree basis are non-fatal:
  warning printed, that worktree skipped, sweep continues.
- Branch deletion (`git branch -D`) is authorized only AFTER the worktree is
  removed (git's cascade rule blocks branch deletion while the worktree is
  registered).
- Detached HEAD worktrees are skipped with a warning (no branch ⇒ no PR
  merged check, no `branch -D` target).
- A 4-AND safety check is required before any deletion: registered linked
  worktree AND PR merged AND clean working tree AND mtime > threshold.
