---
name: sweep
description: Periodic maintenance sweep hub. Dispatches to /sweep-worktrees, /sweep-branches (and future /sweep-wip, /sweep-logs).
user-invocable: true
model: sonnet
---

Hub skill for periodic maintenance sweeps. Dispatches to one or more sub-skills
that each reclaim a specific class of residual state. Default is dry-run; pass
`--apply` to actually delete.

## Procedure

SW-1. Invoke `/sweep-worktrees` (dry-run by default; pass `--apply` to delete).
SW-2. Invoke `/sweep-branches` (dry-run by default; pass `--apply` to delete).
   Capture stdout for post-processing (SW-2b/SW-2c).
SW-2b. Parse sweep-branches stdout for WORKTREE-LOCKED lines.
   Each `WORKTREE-LOCKED: branch=X wt=<path>` line triggers:
   `git -C "$MAIN_ROOT" worktree remove --force "<path>" 2>/dev/null || true`
   This step lives in the hub (not sweep-branches.sh) because the hub has
   worktree-remove authority; sweep-branches.sh does not.
SW-2c. After worktree removal, retry `git branch -D` for each WORKTREE-LOCKED
   branch using the `branch=X` field. SW-2b removes the worktree block, so the
   cascade rule no longer prevents deletion. Failures are ignored (reclaimed
   next cycle).
SW-3. Invoke `/sweep-plans` (dry-run by default; pass `--apply` to delete).
SW-4. Future sub-skills to be added in subsequent PRs:
   - `/sweep-wip` — stale WIP fingerprints
   - `/sweep-logs` — old terminal logs / temp files

Forward `--apply` (and any other flags) to each invoked sub-skill verbatim.

## Rules

- Each sub-skill is independent; one failure does not stop the chain.
- Default is dry-run; pass `--apply` to actually delete.
- Both the nightly cron (`.github/workflows/sweep.yml`) and manual `/sweep` use this hub.
- The nightly cron acts as a workflow health check; zombie reclamation primarily
  relies on manual `/sweep` on the developer's machine, since CI runners do not
  see local worktrees.
- Never pass `--force` — none of the sub-skills accept it by design.
