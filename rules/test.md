# Testing

## Test Writing

Do not write or edit test files directly in the main conversation.

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

- **Security cases**: Verify that security boundaries hold under adversarial input
  Source: OWASP ASVS V8 (Data Protection), OWASP WSTG (Input Validation), CWE Top 25
  - Secret leakage: secrets never appear in output, logs, temp files, or error messages (OWASP ASVS V8)
  - Input injection: malicious CLI args, file paths, and shell metacharacters are rejected or sanitized (OWASP WSTG, CWE-78 OS Command Injection, CWE-22 Path Traversal)
  - Permission: operations respect access control boundaries — unprivileged callers are denied (OWASP ASVS V4 Access Control)
  - Prompt injection: LLM/agent inputs from untrusted sources do not override system instructions or trigger unintended tool calls (OWASP LLM Top 10 LLM01, MCP Top 10 MCP06)
  - Security idempotency: re-running security-relevant operations (e.g., permission grants, secret rotation) does not escalate privileges or leave duplicate entries (extension of Idempotency cases)

## Security vs Test Compatibility

- Never weaken new security to preserve old tests — update the tests instead.

## Test Coverage Review

After writing test code, run `/review-tests` to verify test case completeness before committing.

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

## Test Layer Selection

Follow Martin Fowler's narrow/broad integration distinction and Kent C. Dodds'
Testing Trophy: pick the lowest test layer that can actually fail when the code
under test is broken.

| Layer | What it must catch |
|---|---|
| Static (schema / lint / types) | Config file structure errors, typos in known schemas |
| Unit | Pure logic of a single function with all I/O mocked |
| Narrow integration | Module reads real config files / env vars / fixtures |
| Broad integration | Real subprocess, real filesystem, real plugin/hook registration |
| Smoke (post-install) | "Is it actually wired up in the real environment?" |

### Mandatory integration or E2E coverage

Add an integration or E2E test (not just unit) when the change touches any of
the following — unit tests are structurally blind to these failure modes:

1. **Configuration files** (`settings.json`, YAML, TOML, etc.) — load the real
   file and assert the feature activates. Consider schema validation as a static
   test.
2. **Hook / plugin / event-handler registration** — the test must verify the
   hook actually fires in the real host process, not just that the handler
   function works when called directly.
3. **Subprocess boundaries** — spawn the real CLI and assert on
   stdout/stderr/exit code/side-effect files.
4. **Cross-module wiring** added or modified (DI, routing, event bus).
5. **Regression for a bug that slipped past unit tests** — the regression test
   must live at the layer that would have caught it.

### Deciding whether to write an integration test

Ask: *"If someone deleted the registration / misplaced the config key / renamed
the event, would my unit tests still pass?"* If yes, a unit test is not enough.

## Test Execution Timeout

Always run tests with a timeout (default **120 seconds**). Tests that hang block the entire workflow.

See [test-rules/macos-timeout.md](test-rules/macos-timeout.md) for the portable `run_with_timeout` wrapper (macOS-compatible).

## Claude Code E2E Testing

See [test-rules/claude-e2e.md](test-rules/claude-e2e.md) for precautions when spawning `claude -p` in tests.

## Installer Testing

See [test-rules/installer.md](test-rules/installer.md) for silent installer test patterns (async completion, variable install paths, silent failure, idempotency).
