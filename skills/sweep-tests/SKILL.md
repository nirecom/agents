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
STE-3. Run `bash "$AGENTS_CONFIG_DIR/bin/audit-tests.sh" --dup-groups` — corpus-wide `# Tests:` duplicate-group inventory. Pass no other flag.

## Case-marker embedding (on request only)

STE-4. Only when case-marker embedding is requested: run `bash "$AGENTS_CONFIG_DIR/bin/audit-tests.sh" --embed-cases [--band-size N] [--order frequency|priority] [--dry-run]`, dispatch one subagent per `ITEM` row of the `<<<EMBED-GATE-STE4` block, then run `bash "$AGENTS_CONFIG_DIR/bin/audit-tests.sh" --embed-apply <EMBED_WORKDIR>`.

## Rules

- Every STE-1..STE-4 output is printed verbatim; never summarize or filter one.
- `--embed-cases` covers the whole corpus and behaves the same from either entrypoint, so call one.
- An embed subagent reads its `rules_doc` (and `failure.txt` on a retry) and writes only its `output` directory and `report.txt`.
- On a `<<<EMBED-RETRY-STE4` block, dispatch once more for those rows only, then rerun `--embed-apply` on the same workdir; no second retry block follows.
- Copy `CAPPED`, `TOOL_FAILED`, `CODEX_UNAVAILABLE`, `MERGED_TARGET` and `EXEMPT` lines into the PR body's verification report; a `TOOL_FAILED` file is picked again by the next run.
- The embed protocol (worklist, gate rows, states, retry record) is owned by `docs/architecture/claude-code/sweep-tests-embed-cases.md`.
- For marker-bearing files (`case_begin`/`case_end`), candidacy is per case: a case qualifies when its target is gone (`partial-orphan`); all cases gone → whole-file orphan. For files without markers, a file qualifies once every `# Tests:` path is gone.
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
- `--dup-groups` is read-only; combining it with explicit `--apply`, `--fix-headers`, or `--format json` exits 2.
- `--dup-groups` covers the whole corpus and emits the same TSV from either entrypoint, so call one.
- Missing, duplicated, late, and format-invalid headers become `skip` rows by reason; they never join a group.
- `key` and `files` are escaped; the decoding rule is in the `bin/lib/test-dup-group.sh` header.
