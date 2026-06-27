# Shell Commands

Shell commands, curl, PowerShell, QNAP, Docker HTTP checks, host shell defaults.

When providing shell commands (curl, docker, etc.):
- Always write commands on a single line — do NOT use backslash `\` line continuation

## Host Shell Defaults

| Host | Default shell | Notes |
|------|---------------|-------|
| Windows host | **pwsh (PowerShell)** | `curl.exe` required; WSL sessions use bash/Linux as normal |
| QNAP host | **bash** | No curl/wget — use Python method below |

When suggesting verification commands for the Windows host, default to **pwsh-compatible commands**.
Only use Linux commands when explicitly working inside WSL.

**Claude Code's Bash tool vs user's terminal:**
Bash tool runs in bash — Linux commands work there. Everywhere else (user-facing commands
and `.ps1` scripts), use **PowerShell-native commands**. Do not suggest `grep`, `cp`,
`sed`, `openssl`, etc. directly — see table below.

| bash/Linux | PowerShell equivalent |
|---|---|
| `grep <pattern>` | `Select-String <pattern>` |
| `grep -r` | `Select-String -Recurse` |
| `cat` | `Get-Content` |
| `ls` | `Get-ChildItem` |
| `cp` | `Copy-Item` |
| `rm` / `rm -rf` | `Remove-Item` / `Remove-Item -Recurse -Force` |
| `find` | `Get-ChildItem -Recurse -Filter` |
| `which` | `Get-Command` |
| `touch` | `New-Item` |
| `export VAR=val` | `$env:VAR = "val"` |
| `sed` | `-replace` operator or `[regex]::Replace()` |
| `openssl rand` | Use `/create-key` skill |

**PowerShell environment variables use `$env:` prefix:**
- CORRECT: `$env:MY_API_KEY`
- WRONG: `$MY_API_KEY` (this is a regular PS variable, not an env var)

**curl commands MUST follow all three rules (PowerShell compatibility):**
1. Use `curl.exe` — NEVER bare `curl` (PowerShell aliases it to `Invoke-WebRequest`)
2. Use single quotes for JSON body — NEVER escaped double quotes:
   CORRECT: `curl.exe -d '{"key":"value"}'`
   WRONG:   `curl -d "{\"key\":\"value\"}"`
3. No line continuation — single line only

## QNAP / Docker HTTP Checks

QNAP and most Docker containers do **not** have `curl` or `wget`.
When suggesting HTTP connectivity checks on these environments, use Python directly:

```bash
python3 -c "import urllib.request,ssl;ctx=ssl._create_unverified_context();print(urllib.request.urlopen('URL',context=ctx).read().decode())"
```

Do NOT suggest `curl` → `wget` → Python as a fallback chain. Go straight to Python.

## Docker Restart Caveat

For Docker restart behavior, see `rules/claude-config-source.md`.
