---
name: sweep
description: Periodic maintenance sweep hub. Dispatches to /sweep-worktrees, /sweep-branches, /sweep-plans, /sweep-tests, /sweep-issues.
user-invocable: true
model: sonnet
---

Hub skill for periodic maintenance sweeps. Dispatches to one or more sub-skills
that each reclaim a specific class of residual state. A flagless run applies
(deletes); pass `--dry-run` to preview without writing.

## Procedure

SW-0. Emit `echo <<WORKFLOW_ENFORCE_WORKTREE_OFF: sweep hub — maintenance writes/deletes across sub-skills>>` before SW-1.
SW-1. Invoke `/sweep-worktrees` (deletes by default; pass `--dry-run` to preview).
SW-2. Invoke `/sweep-branches` (deletes by default; pass `--dry-run` to preview).
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
SW-3. Invoke `/sweep-plans` (deletes by default; pass `--dry-run` to preview).
SW-4. Invoke `/sweep-tests` (deletes by default; `--dry-run` and `--fix-headers` are forwarded when passed).
SW-5. Invoke `/sweep-issues` (tier-1 meta-parent closes apply by default; `--dry-run` previews).
   Tier-2 candidates are human-gated and only surface under `--deep`.
SW-6. Emit `echo <<WORKFLOW_ENFORCE_WORKTREE_ON: sweep hub complete>>` after SW-5, regardless of outcome.
SW-7. Future sub-skills to be added in subsequent PRs:
   - `/sweep-wip` — stale WIP fingerprints
   - `/sweep-logs` — old terminal logs / temp files

Forward `--dry-run` (and any other flags) to each invoked sub-skill verbatim.

## Rules

- Each sub-skill is independent; one failure does not stop the chain.
- A flagless run deletes; pass `--dry-run` to preview. `--apply` remains accepted as an explicit synonym of the default.
- Both the nightly cron (`.github/workflows/sweep.yml`) and manual `/sweep` use this hub.
- The nightly cron acts as a workflow health check; zombie reclamation primarily
  relies on manual `/sweep` on the developer's machine, since CI runners do not
  see local worktrees.
- Never pass `--force` — none of the sub-skills accept it by design.
- Never add `--deep` automatically for `/sweep-issues`; it is for human sessions only, so cron and hub runs never stop at a tier-2 gate.
