---
name: sweep-tests
description: Reports (and optionally fixes/removes) stale and orphaned test files.
user-invocable: true
model: sonnet
---

Reports test retire candidates. Default is report-only.

## Procedure

STE-1. Invoke `bin/audit-tests.sh` (issue-specific staleness):
   `bash "$AGENTS_CONFIG_DIR/bin/audit-tests.sh" [--stale-months N] [--offline] [--format text|json] [--fix-headers] [--apply]`
STE-2. Invoke `bin/audit-tests-common.sh` (scope:common orphan detection):
   `bash "$AGENTS_CONFIG_DIR/bin/audit-tests-common.sh" [--format text|json] [--fix-headers]`
STE-3. Print both outputs verbatim. Do not summarize or filter.

## Rules

- Default is report-only (no `--fix-headers`, no `--apply`).
- `--fix-headers` alone: reports format-invalid tokens (FIX_A:/FIX_B:) without rewriting.
- `--fix-headers --apply`: rewrites `# Tests:` headers in-place (atomic, exec-bit preserved). Multi-paren tokens are excluded from auto-rewrite (SKIP_APPLY_MULTI_PAREN).
- `--apply` alone (without `--fix-headers`): deletes stale issue-specific test files (audit-tests.sh only). Only files whose ALL tokens are format-valid (A-flag=false) AND path-deleted (C-class) AND issue CLOSED+stale are deleted.
- Never pass `--apply` alone to `audit-tests-common.sh` — it is unsupported (deletion requires issue staleness context).
- `--offline` suppresses GitHub API calls (issue-specific results will be empty).
