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
Rewriting files through an interpreter script (`node`, `python`, …) counts as a shell-syntax write; use the Edit and Write tools.

## Command-Line Issuance Discipline

Governs what Claude issues through the Bash tool. Scope is the FORM of the command, not its purpose — diagnosis, implementation, git, and file operations are equally in scope.

Default procedure: anything not expressible as one standalone command goes into a scratchpad script, invoked as a single `bash <absolute-path>` call. Never put the compound form on the command line itself.

Create that scratchpad script with the **Write tool**, never with `cat <<'EOF' > file` — the heredoc form trips two prohibited literals (`<<` and `>`) at once, so the escape route would itself violate this rule. The scratchpad root is allowlisted in `hooks/workflow-gate/early-gate.js`, so Write reaches it even while a workflow gate is blocking writes elsewhere.

Name the scratchpad script with a `.sh` extension; invoke it as `bash <absolute-path> [arg…]` — one absolute literal path, optionally followed by literal (non-expanding) arguments; no `$`, backtick, glob, `~`, or other shell-expansion characters in the script path or any argument.
Place it under the current session's scratchpad directory for that invocation to auto-approve without a prompt; `hooks/preuse-auto-approve/scratchpad-script.js` owns the exact condition.

Self-check before every Bash tool call: match the `command` string against the literals below.

The table's data rows are generated from `hooks/bash-guard/forbidden-literals.js`, the same set the `bash-guard` PreToolUse hook enforces — so a literal it blocks is always one this document already told you about. Regenerate: `node "$AGENTS_MAIN_ROOT/bin/print-forbidden-literals" --markdown-table` (edit the module, never the rows).

<!-- BEGIN GENERATED: forbidden-literals -->
| Prohibited literal | Form |
|---|---|
| `&&` / `;` | command chaining |
| `\|` | pipe |
| `` ` `` / `$(...)` | command substitution, variable capture |
| `{ ... }` | grouping |
| `<<` | heredoc |
| `>` / `>>` | redirect |
| `FOO=1 BAR=2 cmd` | leading environment-variable prefixes |
<!-- END GENERATED: forbidden-literals -->

Exempt: one standalone command with its own flags and arguments (one `grep`, one `cat`, one `git status`). The target is the compound, not the argument count.

A Bash call interrupted or rejected with no stated reason means the command line was too long or carried a prohibited literal — fold it into the default procedure and reissue without asking why.
Folding into the default procedure is the only sanctioned reissue; never re-issue a blocked command in another shape (another interpreter, an inline script, split chaining).
When a blocked command cannot be folded, report it and stop.

Command examples inside skill and rules documents specify WHAT to run, never HOW to issue it. Fold a compound example into the default procedure at issue time.

## Subagent Dispatch Prompts

Every prompt that launches a subagent through the Agent tool is in scope — named, general-purpose, Explore, or Plan alike, written by the main conversation or by a skill.
Put the canonical line below into the prompt verbatim, as a standalone line; never copy this rule's body.
Replace `<AGENTS_MAIN_ROOT>` in it with the literal absolute path; a subagent cannot expand `$VAR`.

Read `<AGENTS_MAIN_ROOT>/rules/shell-commands.md` before the first Bash command and before writing a file, follow its Subagent Dispatch Prompts section, and end the final report with a `Command-form deviations` section counting every blocked or rejected command (write `0` when none) unless your own output contract fixes the exact shape of your reply.

Omit the canonical line when dispatching a named agent whose tool list has none of Bash, Write, Edit.
When an agent definition fixes the lines or format of its reply (exactly N lines, a set verdict form, a fixed trailer), that contract wins; add no `Command-form deviations` section.
When the prompt is a JSON object, put the canonical line under the top-level `dispatch_directive` key instead of appending text; treat that key as reserved.
`hooks/subagent-dispatch-prompt.js` appends the line to a prompt that lacks it as a backstop only; the dispatcher still writes the line itself.
The prohibited literals are the generated table above; do not restate them in a dispatch prompt.

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
