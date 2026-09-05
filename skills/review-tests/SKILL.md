---
name: review-tests
description: Codex-primary single-round test coverage review
model: sonnet
context: fork
---

Review test case completeness against source code via Codex (single round, no re-loop).

## Procedure

Note: the Stop-guard silence during dispatch is automatic (PostToolUse marks the step `in_progress`). Do not emit `NEXT_STEP_PAUSE`.

Read `rules/shell-commands.md` before the first Bash command, or before writing a file — defensive measure: RT-2's incident showed the rule content was not effectively available at Bash-issuance time in this `context: fork` execution.

RT-0. Resolve the session-bound linked worktree path: run `"$AGENTS_CONFIG_DIR/bin/resolve-worktree-path"` (Bash, as a single standalone command — no variable-capture syntax on the Bash tool's own command line, per `rules/shell-commands.md`); its stdout is `WORKTREE` for later steps.
  If `WORKTREE == "NOSTATE"`, treat `WORKTREE` as empty — the internal scripts handle the CWD-fallback path for that case.
  Pass it no positional arguments.
  Use no environment-variable prefix on the invocation.
  Use no command chaining: no `&&`, no `;` and no `|` on that command line — per `rules/shell-commands.md`.
  Inspect its exit code, if needed, in a separate, subsequent command.
RT-0a. Read:
   - `rules/core-principles.md`
   - `rules/test.md` — on-demand-only; never auto-injected, so this Read is mandatory
   - `skills/_shared/test-design.md`
   - `skills/_shared/test-design/protection-fix-tests.md` — additionally, for security / guard / classifier fix targets
   - `skills/_shared/test-design/parser-regex-tests.md` — additionally, for parser / regex / allowlist targets
RT-1. Identify staged test file(s) and source file(s):
  - Run `"$AGENTS_CONFIG_DIR/skills/review-tests/scripts/select-staged-files.sh"` (Bash, single standalone command); its stdout is `STAGED`.
  - If exit 3 (linked worktree unresolvable): do NOT fall back to cwd;
    present "Could not identify the linked worktree. Re-run `/review-tests` from the linked worktree, or specify the test and source files manually."
    and ask the user for the files.
  - Select test file(s) and source file(s) from `$STAGED` or from the user's manual input.
RT-2. Assemble review input via the Write tool only — concatenate test file(s) and source file(s) contents into `<PLANS_DIR>/<session-id>-test-review.md`. Do not substitute Bash-based assembly for the Write tool call in this step — see `rules/shell-commands.md` Tool Selection Priority for what counts as shell-based writing. Resolve `<PLANS_DIR>` via `skills/_shared/resolve-plans-dir.md`. Initialize `EXTENSIONS_USED=0`.
RT-3. Invoke `"$AGENTS_CONFIG_DIR/skills/review-tests/scripts/run-codex-review-loop.sh"` (Bash), exporting `AGENTS_CONFIG_DIR`, `SESSION_ID`, `PLANS_DIR`, `EXTENSIONS_USED`. The wrapper auto-adds `--context test-design.md`. Exit-code handling (SSOT: `skills/_shared/codex-review-loop.md`; single-round — no re-loop):
- exit 0 APPROVED → RT-5 COMPLETE.
- exit 1 NEEDS_REVISION → terminal; save stdout to `<PLANS_DIR>/<session-id>-test-review-codex-round-<N>-raw.md` (`<N>` from `<PLANS_DIR>/<session-id>-test-review-last-round.txt`); present gaps; suggest specific test cases → RT-5 WARNINGS (no re-loop).
- exit 2 ESCALATE → run `review-loop-summarize-concerns --budget-remaining 0`; present summary → RT-5 WARNINGS.
- exit 6 HIGH_UNRESOLVED → save stdout to `<PLANS_DIR>/<session-id>-test-review-codex-round-<N>-raw.md` (`<N>` from `<PLANS_DIR>/<session-id>-test-review-last-round.txt`); run `review-loop-summarize-concerns --budget-remaining 0`; present unresolved HIGH concerns → RT-5 WARNINGS (do not emit `WORKFLOW_REVIEW_TESTS_COMPLETE`).
- exit 8 → terminal guard was previously armed (test files unchanged since last terminal); HALT.
- exit 3 → silently launch `test-reviewer` subagent; APPROVED → RT-5 COMPLETE; NEEDS_REVISION → RT-5 WARNINGS.
- exit 4 → HALT with blocking error; do NOT launch fallback; do NOT emit sentinel.
- exit 5 → does not occur (MAX_EXTENSIONS=0); treat as exit 4 HALT if received.
- exit 7 FINALIZE_FAILED → `<PLANS_DIR>/<session-id>-test-review-unresolved-concerns.json` could not be written; HALT, surface the `## Concern Ledger: FINALIZE-FAILED` line, launch no fallback, emit no sentinel. After an ESCALATE, confirm the artifact with `"$AGENTS_CONFIG_DIR/bin/concern-ledger" check-finalized --plans-dir <PLANS_DIR> --session-id <session-id> --format test-review` before RT-5.
RT-4. Triage the concerns against `skills/_shared/priority-hierarchy.md` before emitting the sentinel: a concern that contradicts an approved intent.md / outline.md / detail.md decision — including a documented TL3 gap or a deferral to manual verification — is rejected, not a gap. State each rejection and the decision it rests on, and exclude it from the RT-5c warnings count. Skip on exit 0 (no concerns).
RT-5. Emit workflow sentinel — two separate Bash calls, not chained:
- RT-5a. Run `node "$AGENTS_CONFIG_DIR/bin/compute-staged-tests-token.js" "<WORKTREE-or-empty>"` (Bash, single standalone command, `<WORKTREE-or-empty>` substituted with RT-0's resolved value); its stdout is `TOKEN`.
- RT-5b. (adequate) `echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=${TOKEN}>>"`
- RT-5c. (gaps/warnings) `echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS: token=${TOKEN} warnings=N — blocking: /write-code stays blocked until the gaps are addressed and /review-tests is re-run>>"`
- RT-5d. Skip when `WORKFLOW_WRITE_TESTS_NOT_NEEDED` was emitted (propagated skip).

## Rules

The Test Case Categories checklist lives in `skills/_shared/test-design.md` — do not duplicate it here.
WARNINGS is BLOCKING: `hooks/workflow-gate/review-tests-checker.js` blocks `/write-code` while `warnings_summary` is recorded.
Emit exactly one sentinel per run: COMPLETE on pass, WARNINGS on any gap or warning.
On exit 4 or exit 7, emit neither sentinel and HALT.
Invariant: RT-5 emits exactly one of COMPLETE/WARNINGS; never both, never zero (except exit 4 and exit 7).
Scan scope is limited to files changed in the current PR diff (soft scope). Pre-existing gaps outside the PR diff are excluded.
To accept documented gaps and unblock /write-code, emit `echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: {reason}>>"`.
Only critical and high tier gaps block COMPLETE. Medium and low are advisory.
Worktree resolution is delegated to `bin/resolve-worktree-path` (SSOT: `hooks/workflow-state/resolve-worktree-path.js`); staged file selection is delegated to `scripts/select-staged-files.sh` — do not re-implement inside the skill.
