# Plan Skip Conditions

Shared skip rules for the three-stage planning pipeline.
Each stage's SKILL.md references this file.

| Condition | clarify-intent | design-approach | make-detail-plan |
|---|---|---|---|
| Plan step entirely skipped via `<<WORKFLOW_PLAN_NOT_NEEDED: ...>>` | skip | skip | skip |
| Only one approach obviously viable (`SINGLE_APPROACH_JUSTIFIED`) | run | skip | run |
| Single-file change AND no design decision needed | run | run (or skip via above) | skip |

Rules:
- `SINGLE_APPROACH_JUSTIFIED` is emitted by `approach-designer` only, after clarify-intent has run.
- There is no path to skip `clarify-intent` within the Plan step other than `WORKFLOW_PLAN_NOT_NEEDED`.
- Implicit ("obvious") skipping of any stage is not allowed — use the explicit sentinel.
