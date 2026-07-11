---
name: review-tests
description: Codex-primary single-round test coverage review
model: sonnet
effort: low
context: fork
---

Review test case completeness against source code via Codex (single round, no re-loop).

## Procedure

RT-1. Identify test file(s) and source file(s). Ask the user if ambiguous.
RT-2. Assemble review input — concatenate test file(s) and source file(s) contents into `<PLANS_DIR>/<session-id>-test-review.md` via Write. Resolve `<PLANS_DIR>` via `skills/_shared/resolve-plans-dir.md`. Initialize `EXTENSIONS_USED=0`.
RT-3. Invoke `"$AGENTS_CONFIG_DIR/skills/review-tests/scripts/run-codex-review-loop.sh"` (Bash), exporting `AGENTS_CONFIG_DIR`, `SESSION_ID`, `PLANS_DIR`, `EXTENSIONS_USED`. The wrapper auto-adds `--context test-design.md`. Exit-code handling (SSOT: `skills/_shared/codex-review-loop.md`; exit 1 is TERMINAL):
- exit 0 APPROVED → RT-4 COMPLETE.
- exit 1 NEEDS_REVISION → terminal; save stdout to `<PLANS_DIR>/<session-id>-test-review-codex-round-1-raw.md`; present gaps; suggest specific test cases → RT-4 WARNINGS (no re-loop).
- exit 2 ESCALATE → run `review-loop-summarize-concerns`; present summary → RT-4 WARNINGS.
- exit 3 → silently launch `test-reviewer` subagent; APPROVED → RT-4 COMPLETE; NEEDS_REVISION → RT-4 WARNINGS.
- exit 4 → HALT with blocking error; do NOT launch fallback; do NOT emit sentinel.
- exit 5 → does not occur (MAX_EXTENSIONS=0); treat as exit 4 HALT if received.
RT-4. Emit workflow sentinel — two separate Bash calls, not chained:
- RT-4a. `TOKEN=$(node "$AGENTS_CONFIG_DIR/bin/compute-staged-tests-token.js")`
- RT-4b. (adequate) `echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=${TOKEN}>>"`
- RT-4c. (gaps/warnings) `echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS: token=${TOKEN} warnings=N — blocking: /write-code stays blocked until the gaps are addressed and /review-tests is re-run>>"`
- RT-4d. Skip when `WORKFLOW_WRITE_TESTS_NOT_NEEDED` was emitted (propagated skip).

## Rules

The Test Case Categories checklist lives in `skills/_shared/test-design.md` — do not duplicate it here.
WARNINGS is BLOCKING: `hooks/workflow-gate/review-tests-checker.js` blocks `/write-code` while `warnings_summary` is recorded.
Emit exactly one sentinel per run: COMPLETE on pass, WARNINGS on any gap or warning.
On exit 4, emit neither sentinel and HALT.
Invariant: RT-4 emits exactly one of COMPLETE/WARNINGS; never both, never zero (except exit 4).
Scan scope is limited to files changed in the current PR diff (soft scope). Pre-existing gaps outside the PR diff are excluded.
To accept documented gaps and unblock /write-code, emit `echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: {reason}>>"`.
Only critical and high tier gaps block COMPLETE. Medium and low are advisory.
