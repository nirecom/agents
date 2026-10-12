---
paths:
  - "tests/**"
---

## Test Execution Timeout — Portable Wrapper

Note: `timeout` is not available on macOS. Use `bash "$AGENTS_MAIN_ROOT/bin/run-with-timeout.sh" <seconds> <command>` (works on macOS and Linux; exits 124 on timeout via GNU `timeout` or the perl fallback).

| Runner | Command |
|--------|---------|
| Bash | `bash "$AGENTS_MAIN_ROOT/bin/run-with-timeout.sh" 180 <test-command>` |
| PowerShell (Pester) | Run through `tests/run-all.sh`; the launcher applies the registry's 180 s around the Pester wrapper. Never add `run-with-timeout.sh` yourself |
| pytest | Run through `tests/run-all.sh`; the launcher applies the registry's 180 s around the pytest wrapper. Never add `run-with-timeout.sh` yourself |

Extend the timeout only when the test genuinely requires it (e.g., integration tests with real installs).
