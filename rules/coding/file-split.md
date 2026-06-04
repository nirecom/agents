# File Split Rule

Keep all prompt and code files compact. Split at the thresholds below.
Each pattern has the same axis: entrypoint-private vs shared.

## Pattern A — Code files

- WARN: >300 lines. HARD (must split): >500 lines.
- Keep `<name>.<ext>` as dispatch + re-export only; no logic inside it.
- Entrypoint-private modules: sibling `<name>/` folder.
- Shared across multiple entrypoints: adjacent `lib/` (e.g., `hooks/lib/`).

## Pattern B — SKILL.md

- WARN: >100 lines. HARD (must split): >200 lines.
- Keep `SKILL.md` as the prompt entrypoint; never reduce it to dispatch-only.
- Skill-private procedures (3+ steps): `skills/<name>/scripts/<verb>.sh`.
- Shared across multiple skills or tools: `bin/<tool>`.
