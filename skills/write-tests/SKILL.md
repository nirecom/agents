---
name: write-tests
description: Plan and write test cases with high reasoning effort. Invoked automatically before source code changes.
effort: high
---

Write or update tests for the current task.

## Procedure

1. Read `rules/test.md` for test case categories, naming conventions, and timeout rules.
2. Identify which source file(s) need tests.
3. List all planned test cases by category. Present to the user — do not write code until approved.
4. Write the test file(s).
5. Run tests with timeout.
6. Run `/review-tests` to verify coverage. Fix gaps.

## Rules

- All test rules live in `rules/test.md` — do not duplicate here
