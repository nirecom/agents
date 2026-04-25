---
name: review-plan-security
description: Review architecture security across three axes before implementation planning.
---

Review security implications of the current task before implementation begins.

Evaluate all three axes — do not skip axes that seem irrelevant (report N/A + reason instead).
Reference specific OWASP/CWE identifiers when reporting risks.

For each item, report: PASS / RISK (+ mitigation) / N/A (+ reason).

## Axis 1: Information Leakage (OWASP ASVS V8)

- Secrets (API keys, tokens, passwords) are not hardcoded — use env vars or secret managers
- Sensitive data is not logged, included in error messages, or exposed in stack traces
- `.env` files are gitignored; `.env.example` contains only placeholder values
- PII is not stored in plain text where encryption is feasible
- Build artifacts and temp files do not contain embedded secrets

## Axis 2: Third-Party Access (OWASP MCP Top 10, LLM Top 10)

- MCP servers and tools request only minimum necessary permissions
- Third-party dependencies are pinned to specific versions (not `latest`)
- LLM/agent outputs that trigger actions are validated before execution
- Tool descriptions and return values from untrusted servers are treated as untrusted input
- MCP tool descriptions are reviewed for embedded instruction overrides (MCP04)
- Behavioral changes after initial approval are treated as re-review triggers (MCP09)

## Axis 3: External Access (OWASP WSTG, CWE Top 25)

- All external input is validated and sanitized at system boundaries
- Shell commands do not interpolate unsanitized input (CWE-78)
- File paths from external input are validated against traversal (CWE-22)
- SQL queries use parameterized statements (CWE-89)
- URLs and redirects are validated against allowlists (CWE-601)
- Instruction-override phrases in untrusted input are not forwarded to the LLM (LLM01)

## Output

Present a summary table after evaluation. If any RISK items exist, propose mitigations before proceeding.
