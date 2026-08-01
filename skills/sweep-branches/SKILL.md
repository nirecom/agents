---
name: sweep-branches
description: Reclaim merged-but-undeleted local and remote branches. Deletes by default; --dry-run to preview.
user-invocable: true
model: sonnet
context: fork
---

Reclaims merged-but-undeleted local and remote branches. Local branches are
age-gated (default 24 h); remote branches are only PR-merged checked. Protected
branches (`main`, `master`, `develop`, `release/*`) are never deleted.

## Procedure

SB-1. Resolve `$AGENTS_CONFIG_DIR` from the environment; abort with a clear error
   if unset.
SB-2. Invoke the sweeper script (no flag = deletes; `--dry-run` = preview):
   `bash "$AGENTS_CONFIG_DIR/bin/sweep-branches.sh" [--dry-run] [--min-age-hours N] [--ci-mode]`
SB-3. Print the script's stdout verbatim. Do not summarize or filter.

Forward the user's flags verbatim. Add no flags of your own.

## Rules

- Deletes by default; `--dry-run` must be explicit to preview only.
- `--delete-no-pr` alone deletes no-PR local branches; add `--dry-run` to preview.
- Remote branches use `gh api -X DELETE` (REST API); local branches use `git branch -D` with `SWEEP_BRANCHES_SKILL=1` guard.
- Remote branches are not age-gated (only PR-merged check); local branches are age-gated via `--min-age-hours`.
- `main`, `master`, `develop`, `release/*` are never deleted.
- Non-GitHub remotes are skipped (non-fatal).
- Per-branch failures are non-fatal: warning printed, sweep continues.
- After remote deletion, local tracking refs (`origin/<branch>`) persist until `git fetch --prune`.
