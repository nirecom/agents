---
name: sweep-plans
description: Reclaim stale ~/.workflow-plans/ session artifacts
user-invocable: true
model: sonnet
context: fork
---

# /sweep-plans

Reclaim stale session artifacts under `~/.workflow-plans/`.

## Usage

Invoke `bin/sweep-plans.sh` with forwarded arguments.

Candidates are deleted by default. Pass `--dry-run` to preview without deleting.
Pass `--sweep-age-days N` to override `SWEEP_AGE_DAYS` (default: 30).
