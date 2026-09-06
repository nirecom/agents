---
name: sweep-shell-snapshots
description: Reclaim Claude Code shell snapshots whose PATH line was corrupted by login-shell stdout
user-invocable: true
model: sonnet
context: fork
---

# /sweep-shell-snapshots

Reclaim corrupted shell snapshots under `~/.claude/shell-snapshots/`.

## Usage

Invoke `bin/sweep-shell-snapshots.sh` with forwarded arguments.

Candidates are deleted by default. Pass `--dry-run` to preview without deleting.
Pass `--min-age-minutes N` to hold back snapshots younger than N minutes (default: 1440).
