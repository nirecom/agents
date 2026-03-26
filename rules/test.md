---
description: "Writing or running tests, test planning, test coverage review"
---

# Testing

Before modifying any source code, first create or update test scripts:
- Use the project's existing test directory if one exists; otherwise create `tests/`.
- Tests must cover normal cases, error cases, and edge cases.
- **Before writing test code**, list all planned test cases by category (normal / error / edge)
  and present them to the user. Walk through the edge case checklist below and explicitly
  address each applicable sub-category. Write code only after the user approves the list.
- Run all relevant tests and confirm they pass before committing.

## Test Execution Timeout

Always run tests with a timeout (default **120 seconds**). Tests that hang block the entire workflow.

| Runner | Command |
|--------|---------|
| Bash | `timeout 120 <test-command>` |
| PowerShell (Pester) | `powershell.exe -NoProfile -Command "Invoke-Pester ... "` with Bash `timeout 120` wrapper |
| pytest | `timeout 120 uv run pytest ...` |

Extend the timeout only when the test genuinely requires it (e.g., integration tests with real installs).

## Test Case Categories

- **Normal cases**: Expected inputs and typical usage
- **Error cases**: Invalid inputs, missing resources, permission errors
- **Edge cases**: Boundary values and unexpected-but-valid inputs
  - Numeric: 0, negative, `MAX_INT`, off-by-one
  - String: empty `""`, `null`, single character, extremely long
  - Collection: empty array/list, single element, duplicates
  - File/path: non-existent, empty file, special characters in name

- **Idempotency cases**: Re-running the same operation produces the same result without side effects
  - File/config: re-running doesn't duplicate entries (e.g., same line appended twice to `.bashrc`), template generation produces identical output
  - Cleanup: deletion/uninstall of already-removed targets doesn't error

## Test Coverage Review

After writing test code, run `/review-tests` to verify test case completeness before committing.
This launches an Explore subagent that reads both the source code and the test file,
checks coverage against the Test Case Categories checklist above, and lists any gaps.
Fix gaps before presenting tests to the user.

## Test File Naming

Name test files after the branch they belong to, replacing `/` with `-`:

```
tests/<branch-type>-<branch-name>.<ext>
```

- `feature/claude-rules` → `tests/feature-claude-rules.sh`
- `fix/ssh-keys` → `tests/fix-ssh-keys.sh`
- main direct work: `tests/main-<name>.sh`
- Multiple files per feature: add a suffix (e.g., `feature-claude-rules-global.sh`)

Python (pytest) requires a `test_` prefix for auto-discovery:

| Language | Extension |
|---|---|
| Python (pytest) | `test_<branch-type>-<branch-name>.py` |
| bash | `.sh` |
| PowerShell (Pester) | `.Tests.ps1` |

## Installer Testing

Silent installers (NSIS, Electron-builder, etc.) have non-obvious behaviors that tests must account for:

- **Async completion**: Installers often spawn child processes and return immediately. `Start-Process -Wait` only waits for the parent. Poll for expected artifacts with a timeout instead of trusting process exit.
- **Variable install paths**: Per-user vs per-machine installs use different directories (e.g., `%LOCALAPPDATA%\Programs\` vs `%ProgramFiles%\`). Always check all candidate paths rather than hardcoding one.
- **Silent failure**: Exit code 0 does not guarantee success. Flag combinations that work interactively may silently fail in silent mode (e.g., `/S /currentuser`). Always verify the actual installed artifact exists.

- **Idempotency**: Re-installing doesn't fail or leave inconsistent artifacts. PATH/env additions don't duplicate on re-run. Version-pinned installs produce the same result.
