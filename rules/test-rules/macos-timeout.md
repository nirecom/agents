---
paths:
  - "tests/**"
  - "**/*.sh"
  - "**/*.Tests.ps1"
---

## Test Execution Timeout — Portable Wrapper

Note: `timeout` is not available on macOS. Use this portable wrapper in bash test scripts:

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
