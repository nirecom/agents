---
globs: "docs/history.md,docs/history/**/*.md"
---

## history.md Rules

- Single chronological stream in ascending order (oldest first, newest at end).
- Record completed work with **why** (background, incidents, migration rationale) — not just what was done.
- Use `###` per entry (not tables). Changes and incidents are interleaved chronologically — do NOT use separate `##` sections.
- Incident entries use `### #N:` prefix for identification.
- New entries go at the **end** — never insert in the middle.
- Use `doc-append` CLI to append (see below). Do NOT use Edit tool — it requires a prior Read, consuming context.
- Format:
  ```
  ### Subject (YYYY-MM-DD, commits)
  Background: ...
  Changes: ...
  ```
  Date is mandatory (rebase-proof — commit hashes can become unresolvable). Commit hashes are 7 chars, no GitHub links. Incident entries use `### #N: Subject (YYYY-MM-DD, commits)` with `Cause:` / `Fix:` instead of `Background:` / `Changes:`.

**Archived history** — entries rotated out of `history.md` live under `history/` as separate `.md` files. `history/index.md` is the lookup index (year-grouped list of all archived entries). When searching for information not present in `history.md`, consult `history/index.md` first, then read the specific archive file listed there. Never reconstruct history solely from `history.md`.

## Append-Only Tools

| Tool | When to use |
|------|-------------|
| `doc-append [path] --category CATEGORY ...` | Append a new entry to `history.md` or `CHANGELOG.md`. `--commits` is optional (omit for `CHANGELOG.md`). |
| `uv run bin/doc-rotate.py <path> ...` | Archive old entries when size threshold is exceeded |
| `uv run bin/doc-rotate.py <path> --rebuild-index` | Rebuild `history/index.md` from existing archive files (no rotation) |
| `uv run bin/sort-history.py <path>` | Sort an existing history.md into ascending order |
| `uv run bin/convert-history-table.py <path>` | Convert legacy table-format history.md to `###` format |

`doc-append` categories: `INCIDENT` (numbered, uses `--cause`/`--fix`), `BUGFIX`, `FEATURE`, `REFACTOR`, `CONFIG`, `SECURITY` (all use `--background`/`--changes`).
If `[path]` is omitted, defaults to `docs/history.md` relative to CWD.
Install: `dotfileslink.sh` / `dotfileslink.ps1` generate `~/.local/bin/doc-append` at setup time.

**Rotation thresholds**: `history.md` warns at 500 lines, hard limit at 800 lines.
**Auto-rotation**: `doc-append` automatically invokes `doc-rotate.py --threshold-warn 500 --floor 20` after appending when the resulting file is ≥ 500 lines. Rotation also rebuilds `history/index.md`. Manual `doc-rotate.py --dry-run` is only needed when overriding defaults.
After rotation, `history/index.md` is auto-generated with a year-grouped list of all entries for fast lookup. The index includes a Category Distribution summary and a backtick badge per entry. Run `doc-rotate.py <path> --rebuild-index` to regenerate without rotating.
