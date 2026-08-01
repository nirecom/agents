---
name: sweep-tests
description: Removes stale and orphaned test files (deletes by default; --dry-run previews).
user-invocable: true
model: sonnet
---

Retires stale test files. A flagless run deletes; `--dry-run` reports only.

## Procedure

STE-1. Invoke `bin/audit-tests.sh` (issue-specific staleness):
   `bash "$AGENTS_CONFIG_DIR/bin/audit-tests.sh" [--dry-run] [--stale-months N] [--offline] [--format text|json] [--fix-headers]`
STE-2. Invoke `bin/audit-tests-common.sh` (scope:common orphan detection):
   `bash "$AGENTS_CONFIG_DIR/bin/audit-tests-common.sh" [--dry-run] [--format text|json] [--fix-headers]`
STE-3. Print both outputs verbatim. Do not summarize or filter.

## Rules

- A flagless `audit-tests.sh` run deletes stale issue-specific test files. Only files whose ALL tokens are format-valid (A-flag=false) AND path-deleted (C-class) AND issue CLOSED+stale are deleted.
- `--dry-run` suppresses every write: no deletion, no header rewrite.
- `--fix-headers` rewrites `# Tests:` headers in-place (atomic, exec-bit preserved). Multi-paren tokens are excluded from auto-rewrite (SKIP_APPLY_MULTI_PAREN).
- `--fix-headers --dry-run`: reports format-invalid tokens (FIX_A:/FIX_B:) without rewriting.
- `--apply` is accepted as an explicit synonym of the flagless default.
- `audit-tests-common.sh` has no write path: `--dry-run` is an accepted no-op and `--apply` is rejected (deletion requires issue staleness context).
- `--offline` suppresses GitHub API calls (issue-specific results will be empty).
