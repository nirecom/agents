---
name: sweep-tests
description: Reports stale and orphaned test files. Issue-specific tests closed >N months ago, and scope:common tests whose # Tests: paths all no longer exist.
user-invocable: true
model: sonnet
---

Reports test retire candidates. Dry-run only — no files are deleted.

## Procedure

STE-1. Invoke `bin/audit-tests.sh` (issue-specific staleness):
   `bash "$AGENTS_CONFIG_DIR/bin/audit-tests.sh" [--stale-months N] [--offline] [--format text|json]`
STE-2. Invoke `bin/audit-tests-common.sh` (scope:common orphan detection):
   `bash "$AGENTS_CONFIG_DIR/bin/audit-tests-common.sh" [--format text|json]`
STE-3. Print both outputs verbatim. Do not summarize or filter.

## Rules

- Never pass `--apply` — these scripts are report-only; no deletion is performed.
- `--offline` suppresses GitHub API calls (issue-specific results will be empty).
- Default format is text; pass `--format json` for machine-readable output.
- Do not forward `--apply` from the parent `/sweep` hub (ignored even if passed).
