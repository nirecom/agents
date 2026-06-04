# File Split Rule

Keep all prompt and code files compact. Split at the thresholds below.

## Pattern A — Code files

- WARN: >300 lines. HARD (must split): >500 lines.
- Keep `<name>.<ext>` as dispatch + re-export only; no logic inside it.
- Create a sibling `<name>/` folder; place domain-named modules there.
- Shared utilities across hooks: `hooks/lib/`; otherwise adjacent `lib/`.

## Pattern B — SKILL.md

- WARN: >100 lines. HARD (must split): >200 lines.
- Keep `SKILL.md` as the prompt entrypoint; never reduce it to dispatch-only.
- Skill-private procedures (3+ steps): `skills/<name>/scripts/<verb>.sh`.
- Procedures shared across multiple skills or tools: `bin/<tool>`.
