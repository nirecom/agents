# Documentation Convention

Documentation updates, todo.md, history.md, architecture.md, ops.md, infrastructure.md management.

## Standard Files

| File | Role | Target size | Created |
|------|------|-------------|---------|
| `architecture.md` | What/Why of design decisions (not How — How belongs in `ops.md`) | Unlimited (split into `architecture/` OK) | Always |
| `todo.md` | Current work pointer — reading from top tells you what to do now | <100 lines | Always |
| `history.md` | Completed work with why (background, incidents, decisions) — append-only | Unlimited | On first completion |
| `ops.md` | Operational procedures with actual commands | Unlimited | On demand |
| `infrastructure.md` | **SSOT** for physical machines, network, Docker stacks, ports, and cloud resources per stack/host. Other docs must reference this — never duplicate host placements. | Unlimited | Always (in `ai-specs`) |

Do not use `progress.md` or standalone `roadmap.md` — status tracking belongs in `todo.md`,
completed details in `history.md`, future design specs in `architecture/roadmap.md`.

## Progressive Disclosure (Cascade)

Same-named files at different hierarchy levels provide the same kind of information
scoped to that level. Upper levels contain **summary + pointers**, not duplicated content.
All standard doc types (`todo.md`, `history.md`, `ops.md`) follow the same cascade —
`architecture.md` is shown as an example below.

| Level | Example | Content |
|-------|---------|---------|
| Hub of hubs | `engineering/architecture.md` | One-line per project → links to project `architecture.md` |
| Project hub | `{project}/architecture.md` | Index or flat design doc |
| Detail | `{project}/architecture/overview.md` | Full design detail |

When updating a project-level doc in ai-specs, also update its parent-level counterpart
(e.g. `langchain/todo.md` → `engineering/todo.md`).
Repo-local `docs/` has no parent level — propagation is not needed.

## Doc Location and Commit Hook

The `check-docs-updated` hook blocks commits unless related documentation is also
staged. It automatically searches `docs/` in the repo and sibling `../ai-specs/`.
When committing code changes, ensure the corresponding docs have staged or
unstaged changes.

## Content Rules

- `todo.md`: Current Work section first. Status Summary has incomplete phases only (completed → `history.md`).
  When updating todo.md after completing implementation work, add a **user verification step** as the next action item. The phase/task stays in Current Work with "Verifying" status until the user confirms completion. Do not move it to `history.md` until verification passes.
  Once verification passes, **move** the completed phase/step to `history.md` and **fully remove** it from `todo.md` — do not leave `[x]` checkboxes, completed sub-steps, or stub pointers back to `history.md`. The entry must exist in exactly one place. Status Summary likewise drops completed phases.
- `history.md`: Single chronological stream in ascending order (oldest first, newest at end). Record completed work with **why** (background, incidents, migration rationale) — not just what was done. Use `###` per entry (not tables). Changes and incidents are interleaved chronologically — do NOT use separate `##` sections. Incident entries use `### #N:` prefix for identification. New entries go at the **end** — never insert in the middle. When appending, use Edit with `old_string` matching the trailing blank lines at the end of the file, and `new_string` being those blank lines plus the new entry. Format:
  ```
  ### Subject (YYYY-MM-DD, commits)
  Background: ...
  Changes: ...
  ```
  Date is mandatory (rebase-proof — commit hashes can become unresolvable). Commit hashes are 7 chars, no GitHub links. Incident entries use `### #N: Subject (YYYY-MM-DD, commits)` with `Cause:` / `Fix:` instead of `Background:` / `Changes:`.
  To sort a history.md into ascending order: `uv run bin/sort-history.py <file> --dry-run`
  If `history.md` is in legacy table format, convert using `~/dotfiles/bin/convert-history-table.py`. **Always** present converted output to the user for review before overwriting.
- `infrastructure.md`: Authoritative source for host specs, network topology, Docker stack composition, port allocation, and cloud resources. When adding or moving a service, update `infrastructure.md` first — downstream docs (`architecture.md`, `ops.md`) reference it. Use the `/update-instruction` skill to keep it aligned with infrastructure changes.
- `architecture.md`: Document What/Why. How belongs in `ops.md`
- `ops.md`: Keep procedures actionable with real commands
- Do not duplicate content across documents — cross-reference instead
- **Public repositories**: all documentation must be in English
- **Private repositories**: Japanese is acceptable
