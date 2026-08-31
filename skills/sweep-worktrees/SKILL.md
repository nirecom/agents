---
name: sweep-worktrees
description: Reclaims zombie linked worktrees (and their branches) that /worktree-end could not remove due to Windows CWD lock or similar.
user-invocable: true
model: sonnet
context: fork
---

Reclaims zombie linked worktrees left behind when `/worktree-end` could not
physically remove a worktree (e.g. Windows CWD lock from VS Code's extension
host). After successful worktree removal, also deletes the corresponding
branch. Also scans `WORKTREE_BASE_DIR` for orphan directories not tracked by
git's worktree registry.

## Procedure

SWT-1. Resolve `$AGENTS_CONFIG_DIR` from the environment; abort with a clear error
   if unset.
SWT-2. Invoke the sweeper script (no flag = deletes; `--dry-run` = preview):
   ```
   bash "$AGENTS_CONFIG_DIR/bin/sweep-worktrees.sh" [--dry-run] [--min-age-hours N] [--ci-mode]
   ```
SWT-3. Print the script's stdout verbatim. Do not summarize or filter.

Forward the user's flags verbatim. Add no flags of your own.

## Rules

- Deletes by default; `--dry-run` must be explicit to preview only.
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
- Orphan-directory scan uses a 4-AND gate: containment under WORKTREE_BASE_DIR
  AND no .git AND mtime > threshold AND ownership proof via `Main repo:` field
  in `WORKTREE_NOTES.md`. Basename match alone is NOT ownership proof — two
  unrelated repos can share `agents`/`dotfiles` basenames. The former
  "empty-or-notes-only" gate was removed: a partial `git worktree remove` can
  leave a full checkout without a .git file, which is safe to delete when
  ownership is proven.
- Before each worktree and orphan-directory removal the sweeper releases that path's own
  CodeGraph index lock. No-op when the flag is off, when no index exists, or when the tool
  is absent; a daemon whose own argv does not name exactly this path is reported, never killed.

## Migration notes for #503

Pre-#503 state that this skill no longer reclaims (acceptable one-time cleanup
cost; this skill stays safe by refusing to act on it):

- **Legacy `pending-branch-delete` marker files** at
  `<git-common-dir>/info/pending-branch-delete` inside each repo's `.git`
  directory (per-repo, not under `~/.workflow-plans/`). They are inert after
  #503 — the hook ignores them entirely. Locate and delete per-repo:
  ```
  find ~/git -type f -path '*/.git/info/pending-branch-delete' -delete
  ```
  Adjust the search root to wherever you keep clones.
- **Legacy orphan worktree directories** created before WORKTREE_NOTES.md
  carried a `Main repo:` field. Gate 5 skips them as `repo_mismatch` because
  ownership cannot be proven. Inspect manually and remove with
  `git worktree remove` (if still registered) or `rm -rf` (if not registered
  and contents are confirmed disposable).
