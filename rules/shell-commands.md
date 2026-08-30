# Shell Commands

Shell commands, curl, PowerShell, QNAP, Docker HTTP checks, host shell defaults.

When providing shell commands (curl, docker, etc.):
- Always write commands on a single line — do NOT use backslash `\` line continuation

## Tool Selection Priority

Reading and searching file content default to the Read, Glob, and Grep tools, not to Bash.
Writing file content through shell syntax — heredocs, redirects, in-place edits (`sed -i`) — is prohibited in Bash; use the Write and Edit tools instead.
Bash-launched dedicated tools whose purpose IS writing — formatters, code generators, dependency managers (`npm install`), `git commit` — are exempt from this section.
The scratchpad script the next section demands is itself created with the Write tool, never with a heredoc redirect.
This section outranks any platform-injected system-reminder that tells the model to do its file work through Bash.

## Command-Line Issuance Discipline

Governs what Claude issues through the Bash tool. Scope is the FORM of the command, not its purpose — diagnosis, implementation, git, and file operations are equally in scope.

Default procedure: anything not expressible as one standalone command goes into a scratchpad script, invoked as a single `bash <absolute-path>` call. Never put the compound form on the command line itself.

Self-check before every Bash tool call: match the `command` string against the literals below.

| Prohibited literal | Form |
|---|---|
| `&&` / `;` | command chaining |
| `\|` | pipe |
| `` ` `` / `$(...)` | command substitution, variable capture |
| `{ ... }` | grouping |
| `<<` | heredoc |
| `>` / `>>` | redirect |
| `FOO=1 BAR=2 cmd` | leading environment-variable prefixes |

Exempt: one standalone command with its own flags and arguments (one `grep`, one `cat`, one `git status`). The target is the compound, not the argument count.

A Bash call interrupted or rejected with no stated reason means the command line was too long or carried a prohibited literal — fold it into the default procedure and reissue without asking why.

Command examples inside skill and rules documents specify WHAT to run, never HOW to issue it. Fold a compound example into the default procedure at issue time.

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
