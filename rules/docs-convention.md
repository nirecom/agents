# Documentation Convention

## Standard Files

| File | Role | Target size | Created |
|------|------|-------------|---------|
| `architecture.md` | What/Why of design decisions (not How — How belongs in `ops.md`) | Unlimited (split into `architecture/` OK) | Always |
| `todo.md` | Current work pointer — reading from top tells you what to do now | <100 lines | Always |
| `history.md` | Completed work with why (background, incidents, decisions) — append-only | Unlimited | On first completion |
| `ops.md` | Operational procedures with actual commands | Unlimited | On demand |

Do not use `progress.md` or standalone `roadmap.md` — status tracking belongs in `todo.md`,
completed details in `history.md`, future design specs in `architecture/roadmap.md`.

## Progressive Disclosure (Cascade)

Same-named files at different hierarchy levels provide the same kind of information
scoped to that level. Upper levels contain **summary + pointers**, not duplicated content.

| Level | Example | Content |
|-------|---------|---------|
| Hub of hubs | `engineering/architecture.md` | One-line per project → links to project `architecture.md` |
| Project hub | `{project}/architecture.md` | Index or flat design doc |
| Detail | `{project}/architecture/overview.md` | Full design detail |

## Content Rules

- `todo.md`: Current Work section first. Status Summary has incomplete phases only (completed → `history.md`).
  When updating todo.md after completing implementation work, add a **user verification step** as the next action item. The phase/task stays in Current Work with "Verifying" status until the user confirms completion. Do not move it to `history.md` until verification passes.
- `history.md`: Record completed work with **why** (background, incidents, migration rationale) — not just what was done. Use `###` section per entry (not table — long text is unreadable in tables). Commit hashes only (7 chars, no GitHub links). This prevents re-litigating past decisions in future conversations. Format:
  ```
  ### Subject (commits)
  Background: ...
  Changes: ...
  ```
  Incident entries use `Cause:` / `Fix:` instead of `Background:` / `Changes:`.
- `architecture.md`: Document What/Why. How belongs in `ops.md`
- `ops.md`: Keep procedures actionable with real commands
- Do not duplicate content across documents — cross-reference instead
- Match the existing language style of each file
