---
name: write-tests
description: Plan and write test cases with high reasoning effort. Test iteration runs in a subagent to minimize confirmations.
model: opus
effort: high
---

Write or update tests for the current task.

## Procedure

1. Read `rules/test.md` for test case categories, naming conventions, and timeout rules.
2. Identify which source file(s) need tests.
3. **Enumerate call paths**: For each source file from step 2, trace all integration
   paths it participates in — what calls it, what it calls, and what format/contract
   each boundary expects. For each boundary, list potential failure modes (wrong format,
   missing field, wrong type, unexpected value). These become integration-path error
   cases in the next step.
4. List all planned test cases by category (include call-path error cases from step 3).
   Present to the user — do not write code until approved.
5. **Launch a subagent** (`mode: "default"`) to autonomously:
   a. Write the test file(s).
   b. Run tests with timeout.
   c. Fix failures and re-run until green.
   d. Review test coverage against `rules/test.md` categories — fix gaps.
   e. Re-run tests until green.
   The subagent prompt MUST instruct: edit only test files, never modify source code.
   The subagent prompt MUST also include: "NEVER present diffs for approval. NEVER wait for user confirmation. Edit and run autonomously until tests pass."
6. Present the final test file content to the user for review.

## Rules

- All test rules live in `rules/test.md` — do not duplicate here

## Completion

After completing this skill, stage the test files:
`git add tests/`
The commit gate detects staged tests/ changes as evidence of completion.
If tests are genuinely not needed for this change, run instead:
`echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED>>"`
