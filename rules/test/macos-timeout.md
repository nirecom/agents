---
globs: "tests/**,**/*.sh,**/*.Tests.ps1"
---

## Test Execution Timeout — Portable Wrapper

Note: `timeout` is not available on macOS. Use `bin/run-with-timeout.sh <seconds> <command>` (works on macOS and Linux).

| Runner | Command |
|--------|---------|
| Bash | `bin/run-with-timeout.sh 180 <test-command>` |
| PowerShell (Pester) | `powershell.exe -NoProfile -Command "Invoke-Pester ... "` with Bash `bin/run-with-timeout.sh` wrapper |
| pytest | `bin/run-with-timeout.sh 180 uv run pytest ...` |

Extend the timeout only when the test genuinely requires it (e.g., integration tests with real installs).
