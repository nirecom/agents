---
name: review-plan-security
description: Codex-primary single-round security review of the implementation plan across three axes before implementation.
model: sonnet
context: fork
---

Review security implications of the implementation plan via Codex (single round, no re-loop).

## Procedure

RPS-1. Resolve `<PLANS_DIR>` via `skills/_shared/resolve-plans-dir.md`. Identify `<PLANS_DIR>/<session-id>-detail.md`. Initialize `EXTENSIONS_USED=0`.
RPS-2. Invoke `"$AGENTS_CONFIG_DIR/skills/review-plan-security/scripts/run-codex-review-loop.sh"` (Bash), exporting `AGENTS_CONFIG_DIR`, `SESSION_ID`, `PLANS_DIR`, `EXTENSIONS_USED`. Pass `CTX_SURVEY_CODE`, `CTX_SURVEY_HISTORY`, `CTX_CONCERNS_LOG` as env vars when available. Exit-code handling (SSOT: `skills/_shared/codex-review-loop.md`; single-round — no re-loop):
- exit 0 APPROVED → RPS-5 (no RISK items).
- exit 1 NEEDS_REVISION → terminal; save stdout to `<PLANS_DIR>/<session-id>-security-plan-codex-round-<N>-raw.md` (`<N>` from `<PLANS_DIR>/<session-id>-security-plan-last-round.txt`); stop (no re-loop) → RPS-3.
- exit 2 ESCALATE → run `review-loop-summarize-concerns --budget-remaining 0`; stop → RPS-3.
- exit 6 HIGH_UNRESOLVED → save stdout to `<PLANS_DIR>/<session-id>-security-plan-codex-round-<N>-raw.md` (`<N>` from `<PLANS_DIR>/<session-id>-security-plan-last-round.txt`); run `review-loop-summarize-concerns --budget-remaining 0`; stop → RPS-3.
- exit 3 → silently launch `plan-security-reviewer` subagent; its APPROVED verdict → RPS-5; its NEEDS_REVISION verdict → RPS-3.
- exit 4 → HALT with blocking error; surface wrapper stderr; do NOT launch fallback agent.
- exit 5 → does not occur (MAX_EXTENSIONS=0); treat as exit 4 HALT if received.
- exit 7 FINALIZE_FAILED → `<PLANS_DIR>/<session-id>-security-plan-unresolved-concerns.json` could not be written; HALT, surface the `## Concern Ledger: FINALIZE-FAILED` line, launch no fallback, emit no sentinel. After an ESCALATE, confirm the artifact with `"$AGENTS_CONFIG_DIR/bin/concern-ledger" check-finalized --plans-dir <PLANS_DIR> --session-id <session-id> --format security-plan` first.
RPS-3. Triage — per `skills/_shared/priority-hierarchy.md`, reject a concern only when it directly contradicts a decision already settled in the approved intent.md / outline.md (including their `## Accepted Tradeoffs`).
- Raising a topic the plan does not address is never grounds to reject.
- Rejecting obliges naming the specific governing decision; a reject carrying no cited decision is a procedure violation.
- A concern about the consequences or residual risk of a settled decision is no contradiction of it; only a demand to reverse the decision is.
- Forward each surviving concern to RPS-4.
- When every concern is rejected on a cited decision, treat the review as having no RISK items and go to RPS-5.
- exit 0 carries no concerns and skips this step.
RPS-4. Present the surviving concerns with per-axis severity and proposed mitigations before implementation proceeds.
RPS-5. Summary — APPROVED (including the all-rejected case): report no RISK items, and on the all-rejected path also list every rejected concern beside the settled decision cited against it; NEEDS_REVISION: summarize the RPS-4 mitigations.

## Notes

The three security axes (Information Leakage / Third-Party Access / External Access) and their OWASP/CWE references live in the Codex prompt (`bin/review-plan-codex`) and the `plan-security-reviewer` fallback agent.
For code-level pattern scanning after implementation, use `/review-code-security`.
