# Shell Commands

When providing shell commands (curl, docker, etc.):
- Always write commands on a single line — do NOT use backslash `\` line continuation

## Host Shell Defaults

| Host | Default shell | Notes |
|------|---------------|-------|
| penpen (Windows) | **pwsh (PowerShell)** | `curl.exe` required; WSL sessions use bash/Linux as normal |
| goma (QNAP) | **bash** | No curl/wget — use Python method below |

When suggesting verification commands for penpen, default to **pwsh-compatible commands**.
Only use Linux commands when explicitly working inside WSL.

**curl commands MUST follow all three rules (PowerShell compatibility):**
1. Use `curl.exe` — NEVER bare `curl` (PowerShell aliases it to `Invoke-WebRequest`)
2. Use single quotes for JSON body — NEVER escaped double quotes:
   CORRECT: `curl.exe -d '{"key":"value"}'`
   WRONG:   `curl -d "{\"key\":\"value\"}"`
3. No line continuation — single line only

## QNAP / Docker HTTP Checks

QNAP (goma) and most Docker containers do **not** have `curl` or `wget`.
When suggesting HTTP connectivity checks on these environments, use Python directly:

```bash
python3 -c "import urllib.request,ssl;ctx=ssl._create_unverified_context();print(urllib.request.urlopen('URL',context=ctx).read().decode())"
```

Do NOT suggest `curl` → `wget` → Python as a fallback chain. Go straight to Python.
