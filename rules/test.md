# Testing

## Test Writing

Do not write or edit test files directly in the main conversation.

## Test Coverage Review

After writing test code, run `/review-tests` to verify test case completeness before committing.

## Test Execution Timeout

Always run tests with a timeout (default **120 seconds**). Tests that hang block the entire workflow.

See [test-rules/macos-timeout.md](test-rules/macos-timeout.md) for the portable `run_with_timeout` wrapper (macOS-compatible).

## Claude Code E2E Testing

See [test-rules/claude-e2e.md](test-rules/claude-e2e.md) for precautions when spawning `claude -p` in tests.

## Installer Testing

See [test-rules/installer.md](test-rules/installer.md) for silent installer test patterns (async completion, variable install paths, silent failure, idempotency).