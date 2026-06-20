---
name: write-tests
description: Plan and write test cases with high reasoning effort. Test iteration runs in a subagent to minimize confirmations.
model: sonnet
user-invocable: false
---

Write or update tests for the current task.

## Procedure

1. Read `skills/_shared/test-design.md` for test case categories, naming conventions, and layer selection rules. Also read `rules/test.md` for timeout, E2E, and installer test patterns.
2. Identify which source file(s) need tests.
3. **Enumerate call paths**: For each source file from step 2, trace all integration
   paths it participates in — what calls it, what it calls, and what format/contract
   each boundary expects. For each boundary, list potential failure modes (wrong format,
   missing field, wrong type, unexpected value). These become integration-path error
   cases in the next step.
4. List all planned test cases by category (include call-path error cases from step 3).
   Then check via Bash:
     `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" CONFIRM_TESTS on'`
   - stdout `OFF`: print the planned cases and proceed to step 5 without approval wait.
   - stdout `ON` or `ERROR`: present the planned cases to the user — do not write code until approved (existing behavior).
5. **Determine the subagent's model**:
   - Read `skills/_shared/judge-task-complexity.md` to load the signal table.
   - Evaluate all signals against the task context, source files from steps 2–3, and the planned test cases from step 4. Do not short-circuit on the first match.
   - Apply the routing rule: 1+ signals → `opus`; 0 signals → `sonnet`; ambiguous → `opus`.
   - Emit in Claude text output (NOT Bash echo):
     > Model selected: **[opus|sonnet]** (signals: [comma-separated triggered signal IDs, or "none"])

6. **Launch a subagent** (Agent tool, `mode: "default"`, `model: <model from step 5>`) to autonomously:
   a. Write the test file(s).
   b. Run tests with timeout.
   c. Fix failures and re-run until green.
   d. Review test coverage against `skills/_shared/test-design.md` categories — fix gaps.
   e. Re-run tests until green.
   The subagent prompt MUST include these structured fields so verbose output stays in the subagent context:
   - `task_complexity_signals`: list of triggered signal IDs from step 5 (or "none")
   - `source_files`: list of source file paths from step 2
   - `planned_cases`: list of planned test cases from step 4
   The subagent prompt MUST instruct: edit only test files, never modify source code.
   The subagent prompt MUST also include: "NEVER present diffs for approval. NEVER wait for user confirmation. Edit and run autonomously until tests pass."

7. Present the final test file content to the user for review — gated by **CONFIRM_TESTS gate (post-action review)**:
   `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" CONFIRM_TESTS on'`
   - stdout `OFF`: skip this step; proceed directly to Completion (no user wait).
   - stdout `ON` or `ERROR`: present the test file content.

## Completion

After completing this skill:
1. Stage the test files: `git add tests/`
   The commit gate detects staged tests/ changes as evidence of completion.
2. Run tests.

If tests are genuinely not needed for this change:
1. Run: `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"`
2. Run tests.

## Rules

- Report observations per rules/supervisor-reporting.md.
