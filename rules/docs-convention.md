# Documentation Convention

## Standard Files

Standard docs live under `docs/` within each repository, except `README.md`.
 `docs/` may be a symlink managed by another repo — check before editing.

| File | Role | Target size | Created |
|------|------|-------------|---------|
| `README.md` | Repo's project pitch and entry point — what it does, install, usage, configuration. Write initial install/setup instructions here first. | Compact | Always |
| `CHANGELOG.md` | User-facing release log — what changed and why it matters to users. Written by `/update-docs` via `doc-append CHANGELOG.md` (no `--commits`). Public repos only. | Append-only | Public repos |
| `overview.md` | Highest-level description of a project or directory — vision, goals, and overall shape. Most abstract document in its location. | Compact | Large projects only |
| `architecture.md` | What/Why of design decisions (not How — How belongs in `ops.md`). When split into `architecture/`, the main file is `architecture/design.md`. | <300 lines (split into `architecture/` when exceeded) | Always |
| `architecture/design.md` | Main content file when `architecture.md` is split into `architecture/`. Same What/Why scope as `architecture.md`. Other split files use topical names (e.g. `risks.md`, `stacks.md`). | Unlimited | When `architecture.md` exceeds 300 lines |
| `roadmap.md` | Project-wide goals, milestones, and direction | Compact | Optional |
| `todo.md` | Current work pointer — reading from top tells you what to do now | <100 lines | Always |
| `history.md` | Completed work with why (background, incidents, decisions) — append-only | <500 lines warn / <800 lines hard (rotate when exceeded) | On first completion |
| `ops.md` | Day-to-day operations and procedures too detailed for README.md. Initial install instructions belong in README.md, not here. | Unlimited | On demand |
| `infrastructure.md` | SSOT for physical machines, network, Docker stacks, ports, and cloud resources per stack/host. Other docs must reference this — never duplicate host placements. Path is defined in `CLAUDE.local.md`. | Unlimited | Always |

## Append-Only Tools

Do NOT use Edit tool to append to `history.md` or `CHANGELOG.md` — Edit requires a prior Read, consuming context.
Use the CLI tools instead:

| Tool | When to use |
|------|-------------|
| `doc-append [path] --category CATEGORY ...` | Append a new entry to `history.md` or `CHANGELOG.md`. `--commits` is optional (omit for `CHANGELOG.md`). |
| `uv run bin/doc-rotate.py <path> ...` | Archive old entries when size threshold is exceeded |
| `uv run bin/doc-rotate.py <path> --rebuild-index` | Rebuild `history/index.md` from existing archive files (no rotation) |
| `uv run bin/sort-history.py <path>` | Sort an existing history.md into ascending order |
| `uv run bin/convert-history-table.py <path>` | Convert legacy table-format history.md to `###` format |

`doc-append` categories: `INCIDENT` (numbered, uses `--cause`/`--fix`), `BUGFIX`, `FEATURE`, `REFACTOR`, `CONFIG`, `SECURITY` (all use `--background`/`--changes`).
If `[path]` is omitted, defaults to `docs/history.md` relative to CWD — works from any repo.
Install: `dotfileslink.sh` / `dotfileslink.ps1` generate `~/.local/bin/doc-append` at setup time.

**Rotation thresholds** (arbitrary but documented): `history.md` warns at 500 lines, hard limit at 800 lines.
`architecture.md` warns at 300 lines.

**Auto-rotation**: `doc-append` automatically invokes `doc-rotate.py --threshold-warn 500 --floor 20` after appending when the resulting file is ≥ 500 lines. Rotation also rebuilds `history/index.md`. Manual `doc-rotate.py --dry-run` is only needed when overriding defaults.

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

- `architecture.md`: Document What/Why. How belongs in `ops.md`
- `ops.md`: Day-to-day operations and complex procedures too detailed for README.md. Never write initial install steps here — those belong in README.md.
- Do not duplicate content across documents — cross-reference instead
- `README.md`: Project entry point (What / Install / Usage / Configuration). **Initial install/setup instructions must go here, not in `ops.md`.** Delegate internals to `architecture.md` and detailed procedures to `ops.md` — do not duplicate. Keep concise — link to `docs/` for details.
- `overview.md`: Project vision and overall shape — what it is and why it exists. The most abstract document in its directory. Does not duplicate `architecture.md` design decisions; instead provides the entry-level mental model for a new reader.
- `infrastructure.md`: When adding or moving a service, update `infrastructure.md` first — downstream docs (`architecture.md`, `ops.md`) reference it. Use the `/update-infrastructure` skill to keep it aligned with infrastructure changes.
- `README.md` (ai-specs projects): Lives in the source repo root, not in ai-specs.
- `.env.example`: End-user configuration documentation. For each variable, the comment block must cover **only** these three things, written from the user's perspective:
  1. **What you can do** with this setting (the user-visible effect).
  2. **What you can't do** (limits, what is NOT changed by this setting).
  3. **Format** — value syntax, supported pattern features, and at least one example per supported platform.

  Do NOT include in `.env.example`:
  - Internal hook / module / script names (e.g. `enforce-worktree.js`, `block-dotenv`, `scan-outbound`, `PreToolUse`). The user reading `.env` does not know these.
  - PR numbers or other change-history references — those belong in `history.md`.
  - Implementation details (which layer enforces what, how the regex is built, which file path is checked first).

  Use plain functional language for what guards do (e.g. "secret protection" instead of "block-dotenv hook"). Cross-reference behaviour to user-observable outcomes, never to internal architecture.

## Progressive Disclosure (Cascade)

Same-named files at different hierarchy levels provide the same kind of information
scoped to that level. Upper levels contain **summary + pointers**, not duplicated content.
All standard doc types (`todo.md`, `history.md`, `ops.md`) follow the same cascade —
`architecture.md` is shown as an example below.

| Level | Example | Content |
|-------|---------|---------|
| Hub of hubs | `engineering/architecture.md` | One-line per project → links to project `architecture.md` |
| Project hub | `{project}/architecture.md` | Index or flat design doc |
| Detail | `{project}/architecture/design.md` | Full design detail |

When updating a project-level doc in ai-specs, also update its parent-level counterpart
(e.g. `langchain/todo.md` → `engineering/todo.md`).
Repo-local `docs/` has no parent level — propagation is not needed.
