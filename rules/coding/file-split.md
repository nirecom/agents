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

## Size limits

`hooks/lib/size-limits.js` owns every number; regenerate this table with `bin/print-size-limits --markdown-table`, never edit its rows.
Over WARN is a warning; over HARD is blocked unless the edit shrinks the file.
The `history` row is the rotation threshold `bin/doc-rotate.py` uses, not a split limit.

<!-- BEGIN GENERATED: size-limits -->
| Kind | Applies to | Unit | WARN (over) | HARD (over) |
|---|---|---|---|---|
| code | Code files (`CODE_FILE_EXTENSIONS`, default `js;sh;py`) | lines | 300 | 500 |
| prompt | `skills/**/SKILL.md`, `rules/**/*.md`, `agents/**/*.md`, `skills/_shared/**/*.md` | lines | 100 | 200 |
| docs | Other `.md` files (`docs/**/*.md`, `README.md`) | lines | 300 | 500 |
| history | `history.md`, `CHANGELOG.md` — rotation threshold, used by `bin/doc-rotate.py` | lines | 500 | 800 |
| intent | Plan artifact `<sid>-intent.md` | lines | 100 | 200 |
| outline | Plan artifact `<sid>-outline.md` | lines | 100 | 200 |
| detail | Plan artifact `<sid>-detail.md` | lines | 300 | 500 |
| progress | The `## Current state` section of `<sid>-session-progress.md` | chars | 400 | 600 |
<!-- END GENERATED: size-limits -->

## Pattern A — Code files

- Limit: the `code` row.
- Keep `<name>.<ext>` as dispatch + re-export only; no logic inside it.
- Entrypoint-private modules: sibling `<name>/` folder.
- Shared across multiple entrypoints: adjacent `lib/` (e.g., `hooks/lib/`).
- Long comment blocks inside a code file: `bin/review-comment-block-size` owns that threshold.

## Pattern B — Prompt files (SKILL.md, rules/*.md, agents/*.md, skills/_shared/*.md)

- Limit: the `prompt` row.
- Keep `SKILL.md` as the prompt entrypoint; never reduce it to dispatch-only.
- Skill-private procedures (3+ steps): `skills/<name>/scripts/<verb>.sh`.
- Shared across multiple skills or tools: `bin/<tool>`.
- `rules/*.md` / `agents/*.md` / `skills/_shared/*.md`: split into a sibling `<name>/` directory when the HARD limit is exceeded.

## Pattern C — Documentation files (`docs/**/*.md`, `README.md`)

- Limit: the `docs` row.
- `bin/review-doc-size` owns this check; the `review_docs` step blocks the commit on a HARD violation.
- Over the limit: trim, or split the topic into a `docs/<topic>/` sibling and leave a summary + pointer (CPR-SSOT).
- Exempt (append-only / stream records, never split on size): `history.md`, `CHANGELOG.md`, and any `_archive`/`_archived` path.
- README.md also obeys the section-importance order in `rules/docs/readme.md`, enforced by the same step.

## Pattern D — Plan artifacts (`<sid>-intent.md`, `<sid>-outline.md`, `<sid>-detail.md`)

- Limit: the `intent`, `outline`, and `detail` rows.
- Over WARN: compress — drop restatement, keep decisions and their reasons.
- Over HARD: return the plan to its planner for a compressed revision; never split a plan file.

## Pattern E — Session progress (`## Current state` of `<sid>-session-progress.md`)

- Limit: the `progress` row, counted in characters of that section only.
- Over the limit: rewrite `Current state` as a few lines of now and next; move durable facts to their own sections.
