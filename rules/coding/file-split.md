---
paths:
  - "**/*.js"
  - "**/*.ts"
  - "**/*.py"
  - "**/*.sh"
  - "rules/**/*.md"
  - "skills/**/SKILL.md"
  - "agents/**/*.md"
  - "docs/**/*.md"
  - "README.md"
---

# File Split Rule

Keep all prompt and code files compact. Split at the thresholds below.
Each pattern has the same axis: entrypoint-private vs shared.

## Pattern A — Code files

- WARN: >300 lines. HARD (must split): >500 lines.
- Keep `<name>.<ext>` as dispatch + re-export only; no logic inside it.
- Entrypoint-private modules: sibling `<name>/` folder.
- Shared across multiple entrypoints: adjacent `lib/` (e.g., `hooks/lib/`).
- Long comment blocks inside a code file: `bin/review-comment-block-size` owns that threshold.

## Pattern B — Prompt files (SKILL.md, rules/*.md, agents/*.md, skills/_shared/*.md)

- WARN: >100 lines. HARD (must split): >200 lines.
- Keep `SKILL.md` as the prompt entrypoint; never reduce it to dispatch-only.
- Skill-private procedures (3+ steps): `skills/<name>/scripts/<verb>.sh`.
- Shared across multiple skills or tools: `bin/<tool>`.
- `rules/*.md` / `agents/*.md` / `skills/_shared/*.md`: split into a sibling `<name>/` directory when the HARD limit is exceeded.

## Pattern C — Documentation files (`docs/**/*.md`, `README.md`)

- WARN: >300 lines. HARD (must split): >500 lines.
- `bin/review-doc-size` owns this threshold; the `review_docs` step blocks the commit on a HARD violation.
- Over the limit: trim, or split the topic into a `docs/<topic>/` sibling and leave a summary + pointer (CPR-SSOT).
- Exempt (append-only / stream records, never split on size): `history.md`, `CHANGELOG.md`, and any `_archive`/`_archived` path.
- README.md also obeys the section-importance order in `rules/docs/readme.md`, enforced by the same step.
