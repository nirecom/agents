---
name: write-tests
description: Plan and write test cases with high reasoning effort. Test iteration runs in a subagent to minimize confirmations.
model: sonnet
user-invocable: false
---

Write or update tests for the current task.

## Procedure

Apply `skills/_shared/resolve-plans-dir.md` once; substitute the resolved absolute path for every `<PLANS_DIR>` below.

WT-1. Read:
   - `rules/core-principles.md`
   - `skills/_shared/test-design.md`
   - `rules/test.md` — on-demand-only; never auto-injected, so this Read is mandatory
   For parser / regex / allowlist targets, apply the Table-Driven Tests pattern from `test-design/parser-regex-tests.md`.
WT-2. Identify which source file(s) need tests.
WT-3. **Enumerate call paths**: For each source file from step WT-2, trace all integration
   paths it participates in — what calls it, what it calls, and what format/contract
   each boundary expects. For each boundary, list potential failure modes (wrong format,
   missing field, wrong type, unexpected value). These become integration-path error
   cases in the next step.
WT-4. List all planned test cases by category (include call-path error cases from step WT-3).
   Then check via Bash:
     `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" CONFIRM_TESTS on'`
   - stdout `OFF`: print the planned cases and proceed to step WT-5 without approval wait.
   - stdout `ON` or `ERROR`: present the planned cases to the user — do not write code until approved (existing behavior).
WT-5. **Determine the subagent's model**:
   - Run `bash -c 'node "$AGENTS_CONFIG_DIR/bin/workflow/read-complexity-evaluation" --session "$SESSION_ID" --stage write_tests'`. If line 1 is not `NONE`, use the stored level and signals directly (parse `level=<v>` and `signals=<csv-or-none>`), then derive the model via `high→opus, low→sonnet`; skip the fallback below.
   - If `NONE` (fail-open for sessions without persisted evaluation):
     - Read `skills/_shared/judge-task-complexity.md` and evaluate all signals against the task context, source files from steps WT-2–WT-3, and the planned test cases from step WT-4 — do not short-circuit on the first match.
     - Use the **Write tool** (never Bash) to write the resulting CSV, alone and unquoted, to `<PLANS_DIR>/<session-id>-write-tests-signals.txt` — write only IDs from the generated Valid Signal IDs list; substitute `S0-undecidable` when the judgment doesn't parse into recognized ids or the csv doesn't match `^[A-Za-z0-9,_-]*$` (the judged content is untrusted text, never shell syntax).
     - Run `bash -c 'node "$AGENTS_CONFIG_DIR/bin/workflow/derive-complexity-level" --stage write_tests --signals-file "<PLANS_DIR>/<session-id>-write-tests-signals.txt"'` and use its `level=<v>` — never judge the level inline.
   - Emit in Claude text output (NOT Bash echo):
     > Model selected: **[opus|sonnet]** (signals: [comma-separated triggered signal IDs, or "none"])

WT-6. **Launch a subagent** (Agent tool, `mode: "default"`, `model: <model from step WT-5>`) to autonomously:
   WT-6a. Write the test file(s).
   WT-6b. Run tests with timeout.
   WT-6c. Fix failures and re-run until green.
   WT-6d. Review test coverage against `skills/_shared/test-design.md` categories — fix gaps.
   WT-6e. Re-run tests until green.
   The subagent prompt MUST include these structured fields so verbose output stays in the subagent context:
   - `task_complexity_signals`: the `signals=` line from step WT-5 verbatim (comma-separated IDs, or "none")
   - `source_files`: list of source file paths from step WT-2
   - `planned_cases`: list of planned test cases from step WT-4
   The subagent prompt MUST instruct: edit only test files, never modify source code.
   The subagent prompt MUST instruct: Read `rules/shell-commands.md` before the first Bash command, or before writing a file — general-purpose dispatch does not inherit auto-injected rules.
   The subagent prompt MUST instruct: Read `rules/user-escalation.md` before any system-state-changing command — general-purpose dispatch does not inherit auto-injected rules.
   The subagent prompt MUST instruct: Read `rules/coding.md` (the hub — on-demand-only, so it does not reach you otherwise) and `rules/coding/<lang>.md` for each language present, before the first Edit.
   The subagent prompt MUST instruct: for Bash, PowerShell, JSON, or YAML test files (no `rules/coding/<lang>.md` B-layer exists for these), apply the A-layer language essence from `skills/write-code/SKILL.md`'s "A-layer language essence" section before the first Edit.
   The subagent prompt MUST instruct: Read `rules/test.md` before writing or running tests — on-demand-only, so it does not reach you otherwise; general-purpose dispatch does not inherit auto-injected rules.
   Note: the Stop-guard silence during dispatch is automatic (PostToolUse marks the step `in_progress`). Do not emit `NEXT_STEP_PAUSE`.
   The subagent prompt MUST also include: "NEVER present diffs for approval. NEVER wait for user confirmation. Edit and run autonomously until tests pass."

While the subagent runs, the orchestrator MAY run the WT-7 `CONFIRM_TESTS` gate probe (`bin/confirm-off`) — never read the test files the subagent is still writing (SC-W — `skills/_shared/subagent-concurrency.md`).

WT-7. Present the final test file content to the user for review — gated by **CONFIRM_TESTS gate (post-action review)**:
   `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" CONFIRM_TESTS on'`
   - stdout `OFF`: skip this step; proceed directly to Completion (no user wait).
   - stdout `ON` or `ERROR`: present the test file content.

## Completion

After completing this skill:
1. Stage the test files: `git add tests/`
   The commit gate detects staged tests/ changes as evidence of completion.
   Emit `<<WORKFLOW_MARK_STEP_write_tests_complete>>` from the linked worktree CWD (accepted only when staged or committed test evidence exists).
   Note: Do not emit from main worktree.
   `/review-tests` auto-backfills write_tests when evidence exists; the sentinel is a fallback for edge cases.
2. Run tests (validation only — this does not satisfy the run_tests workflow step).

If tests are genuinely not needed for this change:
1. Run: `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>"`
2. Run tests (validation only — this does not satisfy the run_tests workflow step).

## Rules

- Report observations via /supervisor-report (trigger conditions: rules/supervisor-reporting.md).
