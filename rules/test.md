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

### References

- Fowler, *The Practical Test Pyramid* — https://martinfowler.com/articles/practical-test-pyramid.html
- Fowler, *IntegrationTest* — https://martinfowler.com/bliki/IntegrationTest.html
- Kent C. Dodds, *Write tests. Not too many. Mostly integration.* — https://kentcdodds.com/blog/write-tests
- Kent C. Dodds, *Static vs Unit vs Integration vs E2E Tests* — https://kentcdodds.com/blog/static-vs-unit-vs-integration-vs-e2e-tests

## Test Execution Timeout

Always run tests with a timeout (default **120 seconds**). Tests that hang block the entire workflow.

Note: `timeout` is not available on macOS. Use a portable wrapper in bash test scripts:

```bash
run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 180 "$@"
    else
        perl -e 'alarm 180; exec @ARGV' -- "$@"
    fi
}
```

| Runner | Command |
|--------|---------|
| Bash | `run_with_timeout <test-command>` (use wrapper above) |
| PowerShell (Pester) | `powershell.exe -NoProfile -Command "Invoke-Pester ... "` with Bash `run_with_timeout` wrapper |
| pytest | `run_with_timeout uv run pytest ...` |

Extend the timeout only when the test genuinely requires it (e.g., integration tests with real installs).

## Claude Code CLI (`claude -p`) E2E Testing

When spawning `claude -p` in E2E tests, three precautions are required:

1. **Unset `CLAUDECODE`** — Claude Code sets this env var in its session.
   Child processes inherit it, causing `claude -p` to refuse with
   "nested sessions" error. Always `unset CLAUDECODE` before the call.

2. **Use minimal settings.json** — Copying `claude-global/settings.json` into
   the test repo also copies `disableBypassPermissionsMode: disable`, which
   neutralizes `--dangerously-skip-permissions` and causes a hang.
   Write only the hooks needed by the test:
   ```json
   { "hooks": { "PostToolUse": [...] } }
   ```

3. **WSL-via-Windows bridge masks both issues** — When Claude Code on WSL
   runs through the native Windows binary, `CLAUDECODE` is not propagated
   into the WSL shell and user settings are read from the Windows profile.
   Tests that pass on WSL may still fail on macOS native. Always verify
   E2E tests on a true native environment.

## Installer Testing

See [test-installer.md](test-installer.md) for silent installer test patterns (async completion, variable install paths, silent failure, idempotency).
