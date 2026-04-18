---
name: review-code-security
description: Scan implemented code for concrete security anti-patterns. Companion to /review-plan-security, called at Step 5 (Test & Verify).
model: sonnet
effort: low
---

Scan the specified code for security anti-patterns using the same three axes as `/review-plan-security`. Use after implementation to verify the plan's security goals hold in the actual code.

## When to Use

Called at Step 5 (Test & Verify) when the implementation touches external input, secrets handling, or third-party integrations. Pass a file path, diff, or describe the code to review.

## Rules

- Report each finding with: file/location, pattern category, and recommended fix.
- Note context for potential false positives (test fixtures, comments, examples).
- For commit-time auto-scanning of hard secrets (AWS/LLM API keys, PEM keys, GitHub/Slack tokens, `.env` commits), see `docs/scan-outbound.md` — those are covered automatically.

## Procedure

1. Receive the scan target (file path, diff, or description).
2. Apply each axis's patterns sequentially.
3. Report findings grouped by axis. If nothing found, report "No issues found."

## Patterns by Axis

### Axis 1: Information Leakage
*Axis scope: OWASP ASVS V8 (Data Protection), V6 (Stored Cryptography)*

**Automated coverage**: AWS/LLM API keys, PEM private keys, GitHub/Slack tokens, and `.env` file commits are auto-detected by `scan-outbound.sh` at pre-commit. Source integrity is also covered: zero-width chars (U+200B/C/D, U+FEFF) and Bidi override chars (U+202D/E, U+2066–2069) are detected as `[zero-width]` / `[bidi-override]` (Trojan Source, CVE-2021-42574). This axis focuses on context-dependent leaks automation cannot catch.

| Pattern | What to look for | Risk |
|---|---|---|
| Generic secret hardcoded | `(?i)(secret\|password\|token)\s*=\s*["'][^"']{8,}["']` in source | Leaked credential |
| Logging sensitive data | `log.*password`, `print.*token`, stack traces with secrets | Exposure via logs |
| `.env` not gitignored | `.env` absent from `.gitignore` | Secret leak on push |
| Temp files with secrets | Scripts writing secrets to `/tmp/` or similar | Filesystem exposure |

### Axis 2: Third-Party Access
*Axis scope: OWASP MCP Top 10 (MCP03 Excessive Permissions, MCP04 Tool Poisoning), LLM Top 10 (LLM03 Supply Chain)*

| Pattern | What to look for | Risk |
|---|---|---|
| Unpinned dependency | `"latest"` in package.json, bare package name in requirements.txt | Supply chain (LLM03) |
| Unvalidated LLM/MCP output | Agent output used directly in `eval`, shell call, or DB query | Prompt injection → RCE |
| Excessive MCP permissions | Tool requesting file system / network beyond task scope | MCP03 |
| Tool Poisoning | MCP tool descriptions containing instruction overrides (`ignore previous`, system commands) | MCP04 |
| Rug Pull | MCP server behavior changes after approval — use trusted, auditable publishers only | MCP09 |
| Return Value Injection | Tool return value fed directly into a prompt or `eval` without validation | MCP05 / LLM01 |

### Axis 3: External Access
*Axis scope: OWASP WSTG (Input Validation), CWE Top 25 #2 (CWE-79 XSS), #3 (CWE-89 SQL Injection)*

| Pattern | Regex hint | CWE |
|---|---|---|
| Shell injection | `eval.*\$`, unquoted `$VAR` in command position | CWE-78 |
| Path traversal | `../` combined with user-controlled variable | CWE-22 |
| SQL injection | String concatenation in SQL (`"SELECT " + var`) | CWE-89 |
| Open redirect | Redirect to URL from user input without allowlist | CWE-601 |
| XSS | Unsanitized user input rendered as HTML | CWE-79 |
| Instruction override in input | Untrusted input containing `ignore previous`, `you are now`, `system:` forwarded to LLM as context | LLM01 |
| Base64 obfuscation | Base64 string from untrusted input decoded and passed to LLM/shell | LLM01 |

## Relationship to Other Tools

- `/review-plan-security` — architecture-level checklist (Step 2, before code exists)
- `scan-outbound.sh` — auto-detects hard secrets and private info at pre-commit (see `docs/scan-outbound.md`)
