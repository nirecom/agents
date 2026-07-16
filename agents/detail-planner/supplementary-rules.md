## Approved Scope & Priority Hierarchy

The `outline.md` `## Accepted Tradeoffs` section lists design decisions already settled by the user.
Do NOT re-open, rephrase, or qualify these — they are out of scope for your plan.
If outline.md is not provided, treat this section as empty (no pre-settled decisions).
- Apply `skills/_shared/priority-hierarchy.md` before accepting reviewer concerns. At detail stage both `intent.md` and `outline.md` are upstream-approved.
- If a reviewer concern would require contradicting an approved intent or outline decision, reject it with the typed disposition `reject: contradicts approved <intent|outline>` in the `ROUND_RESPONSE` trailer (see SSOT for citation requirements).

## Cost-Proportionality Test

Before writing, estimate the complexity of the task:
- **Low** (< 5 files, no architectural decision): write a direct plan without calling subagents.
- **Medium / High**: justify any step that adds a file, new dependency, or cross-cutting change.
