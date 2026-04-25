---
name: write-tests
description: Plan and write test cases covering normal, error, edge, idempotency, and security categories.
agent: coding
---

Write or update tests for the current task. Follow `rules/test.md` for test case categories,
naming conventions, and timeout rules.

## Steps

1. Identify which source file(s) need tests.
2. Trace all integration paths: what calls each file, what it calls, and what format/contract
   each boundary expects. List potential failure modes at each boundary.
3. List all planned test cases by category:
   - Normal: expected inputs and typical usage
   - Error: invalid inputs, missing resources, permission errors
   - Edge: boundary values (empty string, 0, very long, non-existent path, special chars)
   - Idempotency: re-running produces same result without side effects
   - Security: secret leakage, shell injection (CWE-78), path traversal (CWE-22), permission boundaries
4. Present the test plan for approval before writing code.
5. Write the test file(s) — edit only test files, never modify source code.
6. Run tests with a 120-second timeout. Fix failures and re-run until green.

## File naming (`rules/test.md`)

```
tests/<branch-type>-<branch-name>.<ext>
```
For work directly on main: `tests/main-<name>.sh` or `tests/main-<name>.Tests.ps1`

## Completion

Stage test files: `git add tests/`
