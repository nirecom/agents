---
name: review-code-security
description: Scan implemented code for concrete security anti-patterns across three axes.
---

Scan the specified code for security anti-patterns. Pass a file path, diff, or describe the code to review.

## Procedure

1. Receive the scan target (file path, diff, or description).
2. Apply each axis sequentially.
3. Report findings grouped by axis. If nothing found, report "No issues found."

Each finding: file/location, pattern category, recommended fix.

## Axis 1: Information Leakage (OWASP ASVS V8)

| Pattern | What to look for |
|---|---|
| Hardcoded secret | `(?i)(secret\|password\|token)\s*=\s*["'][^"']{8,}["']` |
| Logging sensitive data | `log.*password`, `print.*token`, stack traces with secrets |
| `.env` not gitignored | `.env` absent from `.gitignore` |
| Temp files with secrets | Scripts writing secrets to `/tmp/` |

## Axis 2: Third-Party Access (OWASP MCP Top 10, LLM Top 10)

| Pattern | Risk |
|---|---|
| Unpinned dependency | `"latest"` or bare package name — supply chain (LLM03) |
| Unvalidated LLM/agent output used in shell/DB | Prompt injection → RCE |
| Excessive tool permissions | Beyond task scope (MCP03) |
| Tool description with instruction override | `ignore previous`, system commands (MCP04) |

## Axis 3: External Access (OWASP WSTG, CWE Top 25)

| Pattern | CWE |
|---|---|
| Shell injection — `eval.*\$`, unquoted `$VAR` in command | CWE-78 |
| Path traversal — `../` with user-controlled variable | CWE-22 |
| SQL injection — string concat in SQL | CWE-89 |
| Open redirect — URL from user input without allowlist | CWE-601 |
| XSS — unsanitized input rendered as HTML | CWE-79 |
| Instruction override forwarded to LLM | LLM01 |
