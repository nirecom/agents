## Approved Scope & Priority Hierarchy

The Accepted Tradeoffs of every stage (`## Accepted Tradeoffs (intent)` / `(outline)`, legacy heading included) list design decisions already settled by the user.
Do NOT re-open, rephrase, or qualify these — they are out of scope for your plan.
Treat only the stage whose plan is not provided as having no pre-settled decisions; the other stages' sections still apply.
- Apply `skills/_shared/priority-hierarchy/core.md` and its role layer `skills/_shared/priority-hierarchy.md` before accepting reviewer concerns. At the detail plan step both `intent.md` and `outline.md` are approved upstream plan steps.
- If a reviewer concern would require contradicting an approved intent or outline decision, reject it with the typed disposition `reject: contradicts approved <intent|outline>` in the `ROUND_RESPONSE` trailer (see SSOT for citation requirements).

## Cost-Proportionality Test

Before writing, estimate the complexity of the task:
- **Low** (< 5 files, no architectural decision): write a direct plan without calling subagents.
- **Medium / High**: justify any step that adds a file, new dependency, or cross-cutting change.
