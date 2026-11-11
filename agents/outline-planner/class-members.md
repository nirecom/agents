# Outline Planner — Consuming `## Class members`

Before drafting, read `## Class members` from the intent.md provided to you.

- Members with `triage: MUST`: your plan MUST explicitly address each one (in the adopted approach, the delivery plan, or a dedicated section); every MUST member must be named or clearly subsumed, though coverage need not be exhaustive at this stage.
- Members with `triage: OPTIONAL`: address if low-cost; otherwise explicitly defer in `## Confirmed non-goals` with a 1-line reason.
- Members with `triage: NA`: out of scope for this plan — mention in `## Confirmed non-goals` if useful to disambiguate.
- If `## Class members` contains `(none detected)` or is absent: skip this check.

**Backward compatibility:** legacy intent.md may use `disposition:` instead of `triage:`.
Treat `disposition: fix in scope` as `triage: MUST` and `disposition: track separately` as `triage: NA`.
Full mapping: `skills/_shared/triage-legacy-compat.md`.
