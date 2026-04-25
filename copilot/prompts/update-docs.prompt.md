---
name: update-docs
description: Update docs/architecture.md, todo.md, and history.md to reflect recent changes.
---

Update all project documentation to reflect the work just completed.

## Steps

1. Gather recent changes: run `git diff`, `git diff --cached`, and `git log --oneline -20`.
2. Read all target docs: every `.md` in `docs/`, plus the root `README.md`.
3. Identify gaps: unrecorded commits, architecture changes, new incidents, progress updates.
4. Propose updates per file — list which sections and why.
5. Wait for confirmation, then apply.

## Rules (from `rules/docs-convention.md`)

- `todo.md`: completed items move to `history.md` and are fully removed from todo.
- `history.md`: append-only, ascending order. Use `doc-append` CLI if available.
  Entry format:
  ```
  ### Subject (YYYY-MM-DD)
  Background: ...
  Changes: ...
  ```
- `architecture.md`: What/Why only — How belongs in `ops.md`.
- Do not duplicate content across files; cross-reference instead.
- `README.md`: external-facing. Update when a user-visible feature is added or changed.

## Completion

Stage updated docs: `git add docs/ README.md`

If `docs/` is a symlink or junction pointing to another repository, run `git add docs/` in
that target repository instead of (or in addition to) staging here.
