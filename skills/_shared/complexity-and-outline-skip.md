# Complexity Evaluation + Outline-Skip Judgment — Shared Procedure

Canonical procedure for the in-skill step that records the complexity evaluation and settles whether `outline` is skipped.
Referenced by `skills/workflow-init/SKILL.md` (A3a) and `skills/clarify-intent/SKILL.md` (CI-C1b), so the two cannot drift apart (CPR-SSOT).
Substitute `<SESSION_ID>` with its literal value before issuing any command.

## COS-1 — Complexity

Follow `skills/_shared/jev-two-stage-judge.md` with point=`complexity-judge` stage=`complexity`.

## COS-2 — Outline skip

Follow `skills/_shared/jev-two-stage-judge.md` with point=`outline-skip` stage=`complexity`.

## COS-3 — Branch on `SKIP=`

- `SKIP=true` → outline is already settled skipped by finalize; continue with the caller's next step.
- `SKIP=false` → outline runs; continue with the caller's next step.
