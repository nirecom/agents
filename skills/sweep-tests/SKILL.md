---
name: sweep-tests
description: Removes stale and orphaned test files (deletes by default; --dry-run previews).
user-invocable: true
model: sonnet
---

Retires test files whose `# Tests:` targets are gone. A flagless run deletes; `--dry-run` reports only.

## Procedure

STE-1. Run `bash "$AGENTS_CONFIG_DIR/bin/audit-tests.sh" [--dry-run] [--apply] [--stale-months N] [--offline] [--format text|json] [--fix-headers]` — issue-specific scope.
STE-2. Run `bash "$AGENTS_CONFIG_DIR/bin/audit-tests-common.sh" [--dry-run] [--apply] [--stale-months N] [--offline] [--format text|json] [--fix-headers]` — scope:common.
STE-3. Print both outputs verbatim. Do not summarize or filter.

## Rules

- Candidacy is decided by target survival alone: a file qualifies once every `# Tests:` path is gone.
- Issue state never selects a candidate — it gates deletion only.
- Held deletions are reported as `SKIP_DELETE_ISSUE_ACTIVE`, `SKIP_DELETE_METADATA_UNAVAILABLE`, or `SKIP_DELETE_AMBIGUOUS_REF`; the file stays listed and on disk.
- 0 `CANDIDATE:`/`ORPHAN:` lines while `MALFORMED_HEADER:`/`NO_TESTS_HEADER:` lines are present means the survival axis is clear and repair still remains on the header axis.
- A dispatcher and its sibling `tests/<stem>/` folder are retired as one unit.
- `--dry-run` suppresses every write: no deletion, no header rewrite.
- `--apply` is an explicit synonym of the flagless default; both scripts accept it.
- `--fix-headers` reports format-invalid tokens (FIX_A:/FIX_B:) without rewriting; add `--apply` to rewrite `# Tests:` headers in-place (atomic, exec-bit preserved). Multi-paren tokens are excluded from auto-rewrite (SKIP_APPLY_MULTI_PAREN).
- `--fix-headers --dry-run` is report-only as well; no file is ever touched.
- `--offline` skips GitHub API calls; candidates are still reported and deletion of issue-referencing files is held.
- `--stale-months N` (default 3) moves the delete-time staleness boundary only.
