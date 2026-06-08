---
name: sweep-plans
description: Reclaim stale ~/.workflow-plans/ session artifacts
user-invocable: true
model: sonnet
---

# /sweep-plans

Reclaim stale session artifacts under `~/.workflow-plans/`.

## Usage

Invoke `bin/sweep-plans.sh` with forwarded arguments.

Pass `--apply` to delete candidates. Dry-run by default.
Pass `--sweep-age-days N` to override `SWEEP_AGE_DAYS` (default: 30).
