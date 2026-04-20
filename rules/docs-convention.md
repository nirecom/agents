# Documentation Convention

Documentation updates, todo.md, history.md, architecture.md, ops.md, infrastructure.md management.

## Standard Files

| File | Role | Target size | Created |
|------|------|-------------|---------|
| `architecture.md` | What/Why of design decisions (not How — How belongs in `ops.md`) | <300 lines (split into `architecture/` when exceeded) | Always |
| `todo.md` | Current work pointer — reading from top tells you what to do now | <100 lines | Always |
| `history.md` | Completed work with why (background, incidents, decisions) — append-only | <500 lines warn / <800 lines hard (rotate when exceeded) | On first completion |
| `ops.md` | Operational procedures with actual commands | Unlimited | On demand |
| `infrastructure.md` | **SSOT** for physical machines, network, Docker stacks, ports, and cloud resources per stack/host. Other docs must reference this — never duplicate host placements. | Unlimited | Always (in `ai-specs`) |
| `README.md` | Public-facing entry point — what it does, install, usage, configuration. For external users. | Compact | Public repos |

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

## Append-Only Tools

Do NOT use Edit tool to append to `history.md` — Edit requires a prior Read, consuming context.
Use the CLI tools instead:

| Tool | When to use |
|------|-------------|
| `doc-append [path] --category CATEGORY ...` | Append a new entry to any history.md |
| `uv run bin/doc-rotate.py <path> ...` | Archive old entries when size threshold is exceeded |
| `uv run bin/doc-rotate.py <path> --rebuild-index` | Rebuild `history/index.md` from existing archive files (no rotation) |
| `uv run bin/sort-history.py <path>` | Sort an existing history.md into ascending order |
| `uv run bin/convert-history-table.py <path>` | Convert legacy table-format history.md to `###` format |

`doc-append` categories: `INCIDENT` (numbered, uses `--cause`/`--fix`), `BUGFIX`, `FEATURE`, `REFACTOR`, `CONFIG`, `SECURITY` (all use `--background`/`--changes`).
If `[path]` is omitted, defaults to `docs/history.md` relative to CWD — works from any repo.
Install: `dotfileslink.sh` / `dotfileslink.ps1` generate `~/.local/bin/doc-append` at setup time.

**Rotation thresholds** (arbitrary but documented): `history.md` warns at 500 lines, hard limit at 800 lines.
`architecture.md` warns at 300 lines. Run `doc-rotate.py --dry-run` and get user approval before rotating.

After rotation, `history/index.md` is auto-generated with a year-grouped list of all entries for fast lookup. The index includes a Category Distribution summary (count per category) and a backtick badge per entry for at-a-glance category overview. Run `doc-rotate.py <path> --rebuild-index` to regenerate it without rotating (e.g., after manual archive edits or category schema changes).

## Content Rules

- `todo.md`: Current Work section first. Status Summary has incomplete phases only (completed → `history.md`).
  When updating todo.md after completing implementation work, add a **user verification step** as the next action item. The phase/task stays in Current Work with "Verifying" status until the user confirms completion. Do not move it to `history.md` until verification passes.
  Once verification passes, **move** the completed phase/step to `history.md` and **fully remove** it from `todo.md` — do not leave `[x]` checkboxes, completed sub-steps, or stub pointers back to `history.md`. The entry must exist in exactly one place. Status Summary likewise drops completed phases.
- `history.md`: Single chronological stream in ascending order (oldest first, newest at end). Record completed work with **why** (background, incidents, migration rationale) — not just what was done. Use `###` per entry (not tables). Changes and incidents are interleaved chronologically — do NOT use separate `##` sections. Incident entries use `### #N:` prefix for identification. New entries go at the **end** — never insert in the middle. Use `uv run bin/doc-append.py` to append (see Append-Only Tools section). Format:
  ```
  ### Subject (YYYY-MM-DD, commits)
  Background: ...
  Changes: ...
  ```
  Date is mandatory (rebase-proof — commit hashes can become unresolvable). Commit hashes are 7 chars, no GitHub links. Incident entries use `### #N: Subject (YYYY-MM-DD, commits)` with `Cause:` / `Fix:` instead of `Background:` / `Changes:`.

  **Archived history** — entries rotated out of `history.md` live under `history/` as separate `.md` files. `history/index.md` is the lookup index (year-grouped list of all archived entries). When searching for information not present in `history.md`, consult `history/index.md` first, then read the specific archive file listed there. Never reconstruct history solely from `history.md`.

- `infrastructure.md`: Authoritative source for host specs, network topology, Docker stack composition, port allocation, and cloud resources. When adding or moving a service, update `infrastructure.md` first — downstream docs (`architecture.md`, `ops.md`) reference it. Use the `/update-instruction` skill to keep it aligned with infrastructure changes.
- `architecture.md`: Document What/Why. How belongs in `ops.md`
- `ops.md`: Keep procedures actionable with real commands
- Do not duplicate content across documents — cross-reference instead
- `README.md`: External-facing overview (What / Install / Usage / Configuration). Delegate internals to `architecture.md` and procedures to `ops.md` — do not duplicate. For ai-specs projects, `README.md` lives in the source repo root (not in ai-specs). Keep concise — link to `docs/` for details.
