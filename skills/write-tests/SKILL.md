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
3. List all planned test cases by category. Present to the user — do not write code until approved.
4. **Launch a subagent** (`mode: "default"`) to autonomously:
   a. Write the test file(s).
   b. Run tests with timeout.
   c. Fix failures and re-run until green.
   d. Review test coverage against `rules/test.md` categories — fix gaps.
   e. Re-run tests until green.
   The subagent prompt MUST instruct: edit only test files, never modify source code.
   The subagent prompt MUST also include: "NEVER present diffs for approval. NEVER wait for user confirmation. Edit and run autonomously until tests pass."
5. Present the final test file content to the user for review.

## Rules

- All test rules live in `rules/test.md` — do not duplicate here

## Completion

After completing this skill, run:
`node "$DOTFILES_DIR/claude-global/hooks/mark-step.js" write_tests complete`
