---
name: review-plan-security
description: Codex-primary single-round security review of the implementation plan across three axes before implementation.
model: opus
effort: medium
context: fork
---

Review security implications of the implementation plan via Codex (single round, no re-loop).

## Procedure

RPS-1. Resolve `<PLANS_DIR>` via `skills/_shared/resolve-plans-dir.md`. Identify `<PLANS_DIR>/<session-id>-detail.md`. Initialize `EXTENSIONS_USED=0`.
RPS-2. Invoke `"$AGENTS_CONFIG_DIR/skills/review-plan-security/scripts/run-codex-review-loop.sh"` (Bash), exporting `AGENTS_CONFIG_DIR`, `SESSION_ID`, `PLANS_DIR`, `EXTENSIONS_USED`. Pass `CTX_SURVEY_CODE`, `CTX_SURVEY_HISTORY`, `CTX_CONCERNS_LOG` as env vars when available. Exit-code handling (SSOT: `skills/_shared/codex-review-loop.md`; exit 1 is TERMINAL):
- exit 0 APPROVED → RPS-4 (no RISK items).
- exit 1 NEEDS_REVISION → terminal; save stdout to `<PLANS_DIR>/<session-id>-security-plan-codex-round-1-raw.md`; present concerns with per-axis severity; propose mitigations; stop (no re-loop) → RPS-3.
- exit 2 ESCALATE → run `review-loop-summarize-concerns`; present summary; stop → RPS-3.
- exit 3 → silently launch `plan-security-reviewer` subagent; use its verdict for RPS-4.
- exit 4 → HALT with blocking error; surface wrapper stderr; do NOT launch fallback agent.
- exit 5 → does not occur (MAX_EXTENSIONS=0); treat as exit 4 HALT if received.
RPS-3. Present concerns with per-axis severity and proposed mitigations before implementation proceeds.
RPS-4. Summary — APPROVED: report no RISK items; NEEDS_REVISION: summarize mitigations.

## Notes

The three security axes (Information Leakage / Third-Party Access / External Access) and their OWASP/CWE references live in the Codex prompt (`bin/review-plan-codex`) and the `plan-security-reviewer` fallback agent.
For code-level pattern scanning after implementation, use `/review-code-security`.
