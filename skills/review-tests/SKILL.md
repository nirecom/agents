---
name: review-tests
description: Codex-primary test coverage review
model: sonnet
context: fork
---

Review test case completeness against source code via Codex (round-continuing under the 2+1 cap: address gaps and re-run).

## Procedure

Note: the Stop-guard silence during dispatch is automatic (PostToolUse marks the step `in_progress`). Do not emit `NEXT_STEP_PAUSE`.

Read `rules/shell-commands.md` before the first Bash command, or before writing a file — defensive measure: RT-2's incident showed the rule content was not effectively available at Bash-issuance time in this `context: fork` execution.

RT-0. Resolve the session-bound linked worktree path in two separate standalone Bash commands — never combined with variable-capture syntax on the Bash tool's own command line, per `rules/shell-commands.md`.
  RT-0 step 1: run `bash "$AGENTS_CONFIG_DIR/bin/resolve-session-id"`; its stdout is the CC session id.
  RT-0 step 1 exit 2 (stdout empty, stderr `session id unresolvable`): omit `--session` and run step 2 anyway.
  RT-0 step 1 any other non-zero exit (3 = resolver fault, 127 = node absent): HALT and surface its stderr; do not run step 2 — rc 3 is a fault, not "no session".
  RT-0 step 2: run `bash "$AGENTS_CONFIG_DIR/bin/resolve-worktree-path" --session <value from step 1>`; its stdout is `WORKTREE` for later steps.
  RT-0 step 2 exit 2 (malformed `--session` value — a transcription error): HALT; never fall through to a different session.
  If step 2's stdout is empty after an omitted `--session`, RT-0 skips: the review target cannot be identified.
  If `WORKTREE == "NOSTATE"`, treat `WORKTREE` as empty — the internal scripts handle the CWD-fallback path for that case.
  Pass each script path to `bash` as its argument, keeping `bash` itself in execution position — a bare quoted path there is a shell variable in execution position, the shape the permission engine's allow rules never match.
  Pass it no arguments other than `--session <value>`.
  Use no environment-variable prefix on either invocation.
  Use no command chaining: no `&&`, no `;` and no `|` on those command lines — per `rules/shell-commands.md`.
  Inspect an exit code, if needed, in a separate, subsequent command.
RT-0a. Read:
   - `rules/core-principles.md`
   - `rules/test.md` — on-demand-only; never auto-injected, so this Read is mandatory
   - `skills/_shared/test-design.md`
   - `skills/_shared/test-design/protection-fix-tests.md` — additionally, for security / guard / classifier fix targets
   - `skills/_shared/test-design/parser-regex-tests.md` — additionally, for parser / regex / allowlist targets
RT-1. Identify staged test file(s) and source file(s):
  - Run `bash "$AGENTS_CONFIG_DIR/skills/review-tests/scripts/select-staged-files.sh"` (Bash, single standalone command); its stdout is `STAGED`.
  - If exit 3 (linked worktree unresolvable): do NOT fall back to cwd;
    present "Could not identify the linked worktree. Re-run `/review-tests` from the linked worktree, or specify the test and source files manually."
    and ask the user for the files.
  - If exit 4 (`bin/resolve-session-id` faulted): HALT, surface the script's stderr, and do NOT ask for a manual file.
  - Select test file(s) and source file(s) from `$STAGED` or from the user's manual input.
RT-1a. Check each newly added test file for a missed append target:
  - Run `bash "$AGENTS_CONFIG_DIR/skills/review-tests/scripts/select-staged-files.sh" --added-only` (Bash, single standalone command); its stdout is `ADDED`. Exit 3 / exit 4 are handled exactly as in RT-1.
  - For each `ADDED` entry under `tests/`, run `bash "$AGENTS_CONFIG_DIR/bin/find-tests-for-source.sh" --test-file <path> --root <WORKTREE>` (Bash, one standalone command per file; omit `--root` when `WORKTREE` is empty). The helper itself returns `skipped`/`not-top-level` for nested part files — do not pre-filter by eye.
  - The gap predicate is the row's `viable` column alone, never the `verdict` column: a non-`-` `viable` column means an append target under the HARD limit existed for this file's `# Tests:` set.
  - A non-`-` `viable` column is a `high`-tier gap "append candidate existed but a new file was created". A `# Tags:` `dup-group-keep:size-hard-limit` does NOT waive it — the same row disproves the tag by showing a sub-HARD target. No `dup-group-keep:<reason>` value waives anything; the only escape is the WARNINGS_ACCEPTED sentinel.
  - Validate the tag's claim, not its presence: when the file's `# Tags:` carries `dup-group-keep:size-hard-limit`, the row corroborates it only if `excluded` is non-`-` and `reason` is `size-hard-limit`. A tag on a row with `excluded` = `-` (`reason=no-candidate` — no append candidate ever existed) is an unvalidated opt-out: report it at the same `high` tier as a missed append target.
  - Feed the gaps into RT-3's review input and count them in RT-5c.
RT-2. Assemble review input via the Write tool only — concatenate test file(s) and source file(s) contents into `<PLANS_DIR>/<session-id>-test-review.md`. Do not substitute Bash-based assembly for the Write tool call in this step — see `rules/shell-commands.md` Tool Selection Priority for what counts as shell-based writing. Resolve `<PLANS_DIR>` via `skills/_shared/resolve-plans-dir.md`. Initialize `EXTENSIONS_USED=0`.
RT-3. Invoke `"$AGENTS_CONFIG_DIR/skills/review-tests/scripts/run-codex-review-loop.sh"` (Bash), exporting `AGENTS_CONFIG_DIR`, `SESSION_ID` (plan-artifact prefix), `PLANS_DIR`, `EXTENSIONS_USED`. The wrapper auto-adds `--context test-design.md`. Exit-code handling (SSOT: `skills/_shared/codex-review-loop.md`; round-continuing under the 2+1 cap):
- exit 0 APPROVED → RT-5 COMPLETE.
- exit 1 NEEDS_REVISION → save stdout to `<PLANS_DIR>/<session-id>-test-review-codex-round-<N>-raw.md` (`<N>` from `<PLANS_DIR>/<session-id>-test-review-last-round.txt`); present gaps; suggest specific test cases → RT-5 WARNINGS. WARNINGS is blocking: address the gaps, re-stage tests, and re-run `/review-tests` — the round counter survives, so the re-run is counted as the next round.
- exit 2 ESCALATE → run `review-loop-summarize-concerns --budget-remaining 0`; present summary → RT-5 WARNINGS.
- exit 6 HIGH_UNRESOLVED → save stdout to `<PLANS_DIR>/<session-id>-test-review-codex-round-<N>-raw.md` (`<N>` from `<PLANS_DIR>/<session-id>-test-review-last-round.txt`); run `review-loop-summarize-concerns --budget-remaining 0`; present unresolved HIGH concerns → RT-5 WARNINGS (do not emit `WORKFLOW_REVIEW_TESTS_COMPLETE`).
- Exits 2 and 6 are terminal: after RT-5 WARNINGS, do NOT re-invoke write-tests or re-run `/review-tests` — accept remaining gaps via `echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: {reason}>>"` or address them in a new session.
- exit 8 → terminal guard was previously armed (test files unchanged since last terminal); HALT.
- exit 3 → silently launch `test-reviewer` subagent; APPROVED → RT-5 COMPLETE; NEEDS_REVISION → RT-5 WARNINGS.
- exit 4 → HALT with blocking error; surface wrapper stderr; do NOT launch fallback; do NOT emit sentinel.
- exit 5 AUTO_EXTEND → same as exit 1 (gaps remain within the extension budget): present gaps → RT-5 WARNINGS; address and re-run.
- exit 7 FINALIZE_FAILED → `<PLANS_DIR>/<session-id>-test-review-unresolved-concerns.json` could not be written; HALT, surface the `## Concern Ledger: FINALIZE-FAILED` line, launch no fallback, emit no sentinel. After an ESCALATE, confirm the artifact with `bash "$AGENTS_CONFIG_DIR/bin/concern-ledger" check-finalized --plans-dir <PLANS_DIR> --session-id <session-id> --format test-review` before RT-5.
RT-4. Triage the concerns against `skills/_shared/priority-hierarchy.md` before emitting the sentinel: a concern that contradicts an approved intent.md / outline.md / detail.md decision — including a documented TL3 gap or a deferral to manual verification — is rejected, not a gap. State each rejection and the decision it rests on, and exclude it from the RT-5c warnings count. Skip on exit 0 (no concerns).
RT-5. Emit workflow sentinel — two separate Bash calls, not chained:
- RT-5a. Run `node "$AGENTS_CONFIG_DIR/bin/compute-staged-tests-token.js" "<WORKTREE-or-empty>"` (Bash, single standalone command, `<WORKTREE-or-empty>` substituted with RT-0's resolved value); its stdout is `TOKEN`.
- RT-5b. (adequate) `echo "<<WORKFLOW_REVIEW_TESTS_COMPLETE: token=${TOKEN}>>"`
- RT-5c. (gaps/warnings) `echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS: token=${TOKEN} warnings=N — blocking: /write-code stays blocked until the gaps are addressed and /review-tests is re-run>>"`
- RT-5d. Skip when `WORKFLOW_WRITE_TESTS_NOT_NEEDED` was emitted (propagated skip).

RT-6. Record the emitted sentinel as `--class E --step review_tests --key review-tests:sentinel`, per `skills/_shared/handoff-record.md`.

## Rules

The Test Case Categories checklist lives in `skills/_shared/test-design.md` — do not duplicate it here.
The append-vs-new criteria live in `skills/_shared/test-design/append-vs-new.md` — do not restate them here.
WARNINGS is BLOCKING: `hooks/workflow-gate/review-tests-checker.js` blocks `/write-code` while `warnings_summary` is recorded.
Emit exactly one sentinel per run: COMPLETE on pass, WARNINGS on any gap or warning.
On exit 4 or exit 7, emit neither sentinel and HALT.
Invariant: RT-5 emits exactly one of COMPLETE/WARNINGS; never both, never zero (except exit 4 and exit 7).
Scan scope is limited to files changed in the current PR diff (soft scope). Pre-existing gaps outside the PR diff are excluded.
To accept documented gaps and unblock /write-code, emit `echo "<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: {reason}>>"`.
Only critical and high tier gaps block COMPLETE. Medium and low are advisory.
Session-id resolution is delegated to `bin/resolve-session-id` and its value passed on as `--session`; worktree resolution is delegated to `bin/resolve-worktree-path` (SSOT: `hooks/workflow-state/resolve-worktree-path.js`); staged file selection is delegated to `scripts/select-staged-files.sh` — do not re-implement inside the skill.
