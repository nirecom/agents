---
name: sweep
description: Periodic maintenance sweep hub. Dispatches to /sweep-worktrees (and future /sweep-branches, /sweep-markers, /sweep-wip, /sweep-logs).
user-invocable: true
model: sonnet
---

Hub skill for periodic maintenance sweeps. Dispatches to one or more sub-skills
that each reclaim a specific class of residual state. Default is dry-run; pass
`--apply` to actually delete.

## Procedure

1. Invoke `/sweep-worktrees` (dry-run by default; pass `--apply` to delete).
2. (PR2) Future sub-skills to be added in subsequent PRs:
   - `/sweep-branches` — merged-but-undeleted local branches
   - `/sweep-wip` — stale WIP fingerprints
   - `/sweep-logs` — old terminal logs / temp files
   - `/sweep-markers` — legacy marker files from retired Phase 1 mechanism

Forward `--apply` (and any other flags) to each invoked sub-skill verbatim.

## Rules

- Each sub-skill is independent; one failure does not stop the chain.
- Default is dry-run; pass `--apply` to actually delete.
- Both the nightly cron (`.github/workflows/sweep.yml`) and manual `/sweep` use this hub.
- The nightly cron acts as a workflow health check; zombie reclamation primarily
  relies on manual `/sweep` on the developer's machine, since CI runners do not
  see local worktrees.
- Never pass `--force` — none of the sub-skills accept it by design.
