---
name: review-plan-security
description: Review architecture security across three axes before implementation planning. Companion to /review-code-security (called at Step 5 for code-level patterns).
model: opus
effort: medium
---

Review security implications of the current task across three axes.

## Rules

- **TodoWrite is mandatory.** Do not evaluate inline without it.
- Evaluate all three axes — do not skip axes that seem irrelevant (report N/A instead).
- Reference specific OWASP/CWE identifiers when reporting risks.
- This checklist is for architecture/planning review — code-level pattern scanning is covered by `/review-code-security` (companion skill, called at Step 5).

## Procedure

1. Read the implementation plan or task description.
2. Register all checklist items from the three axes into TodoWrite
   (one task per item, prefixed with axis name, e.g. "Leakage: secrets not hardcoded").
3. Evaluate each item sequentially — set `in_progress`, evaluate, then `completed` with: PASS / RISK (+ mitigation) / N/A (+ reason).
4. Present a summary table. If any RISK items exist, propose mitigations before implementation proceeds.

## Security Axes

### Axis 1: Information Leakage
Source: OWASP ASVS V8 (Data Protection), V6 (Stored Cryptography)

- Secrets (API keys, tokens, passwords) are not hardcoded — use env vars or secret managers
- Sensitive data is not logged, included in error messages, or exposed in stack traces
- `.env` files are gitignored; `.env.example` contains only placeholder values
- PII is not stored in plain text where encryption is feasible
- Build artifacts and temp files do not contain embedded secrets

For concrete detection patterns, see `/review-code-security` Axis 1.

### Axis 2: Third-Party Access
Source: OWASP MCP Top 10 (MCP03 Excessive Permissions, MCP04 Tool Poisoning), LLM Top 10 (LLM03 Supply Chain)

- MCP servers and tools request only minimum necessary permissions
- Third-party dependencies are pinned to specific versions (not `latest`)
- LLM/agent outputs that trigger actions are validated before execution
- Tool descriptions and return values from untrusted MCP servers are treated as untrusted input
- Supply chain: new dependencies are from reputable sources with active maintenance
- MCP tool descriptions are reviewed for embedded instruction overrides (MCP04 Tool Poisoning)
- MCP servers are sourced from trusted, auditable publishers; behavioral changes after initial approval are treated as re-review triggers (Rug Pull, MCP09)
- Tool return values are validated before acted on; injected instructions in tool results do not propagate (Return Value Injection, MCP05)

For concrete detection patterns, see `/review-code-security` Axis 2.

### Axis 3: External Access
Source: OWASP WSTG (Input Validation), CWE Top 25 #2 (CWE-79 XSS), #3 (CWE-89 SQL Injection)

- All external input is validated and sanitized at system boundaries
- Shell commands do not interpolate unsanitized input (CWE-78 OS Command Injection)
- File paths from external input are validated against traversal (CWE-22 Path Traversal)
- SQL queries use parameterized statements, not string concatenation (CWE-89)
- URLs and redirects are validated against allowlists (CWE-601 Open Redirect)
- Instruction-override phrases in untrusted input (e.g. `ignore previous instructions`, `system:`) are flagged and not forwarded to the LLM as trusted context (OWASP LLM Top 10 LLM01)
- Base64-encoded strings in untrusted input are not auto-decoded and fed to LLM/shell without explicit validation

For concrete detection patterns, see `/review-code-security` Axis 3.

## Source Integrity

Source files must not contain Unicode characters that diverge display from execution (Trojan Source, CVE-2021-42574). Hidden/invisible chars (zero-width, Bidi overrides) are auto-detected by `scan-outbound.sh` at pre-commit; see `/review-code-security` Axis 1 automated coverage.

For PostToolUse-level prompt-injection defense on tool results (e.g. `WebFetch` output), see planned Phase 5 hook (`docs/todo.md`).
