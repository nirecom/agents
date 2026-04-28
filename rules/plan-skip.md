# Plan Skip Conditions

Shared skip rules for the three-stage planning pipeline.
Each stage's SKILL.md references this file.

`clarify-intent` (step 1) is a mandatory pre-Plan step — it runs regardless of whether Plan
is skipped and has no skip path.

| Condition | research (2a) | make-outline-plan (2b) | make-detail-plan (2c) |
|---|---|---|---|
| Plan step entirely skipped via `<<WORKFLOW_PLAN_NOT_NEEDED: ...>>` | skip | skip | skip |
| Only one approach obviously viable (`SINGLE_APPROACH_JUSTIFIED`) | run | skip | run |
| Single-file change AND no design decision needed | run | run (or skip via above) | skip |

Rules:
- `SINGLE_APPROACH_JUSTIFIED` is emitted by `outline-planner` only, after clarify-intent has run.
- `<<WORKFLOW_PLAN_NOT_NEEDED>>` skips the entire Plan stage (research 2a + make-outline-plan 2b + make-detail-plan 2c).
- Implicit ("obvious") skipping of any stage is not allowed — use the explicit sentinel.
