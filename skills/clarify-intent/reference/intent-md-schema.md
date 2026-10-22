# intent.md Schema

Referenced by CI-4. Format rules for `<PLANS_DIR>/<session-id>-intent.md`.

## Section order

1. H1 title
2. `**Title:** <human-readable one-line title>` — data contract read by Path C for `gh issue create --title`.
3. `**PM type:** waterfall` — the project-management type recorded when clarify_intent completes; only `waterfall` is accepted (`agile` is reserved for #2565).
4. `## Issues` (mandatory — see rules below)
5. `## Glossary` (mandatory heading, body may be empty — see schema below)
6. Background/Motivation
7. Scope
8. Constraints
9. Interview Log (optional)
10. `## Class members` (mandatory — see schema below)
11. `## Accepted Tradeoffs` (`### <title>` heading + 1-paragraph rationale per entry; empty → write `(none)`) — captures design decisions already settled, used by `extract-mandatory-sections` to suppress re-raised concerns in later codex reviews.
12. `## worktrees` (optional — omit for single-repo sessions; include when CI-3b collected sibling worktree paths)

Language: write body text in `PLAN_LANG` (`$AGENTS_MAIN_ROOT/.env`) when it is a concrete non-English language; schema H2 heading lines always use their canonical English names regardless of `PLAN_LANG`. `PLAN_LANG` unset/`any`/`english` → write body text in English.

## `## Issues` schema (mandatory)

Immediately after the `**PM type:**` line, before Background/Motivation. Single SSOT for `closes_issues` — no separate `## closes_issues` section.

- One entry line per issue in `closes_issues`, in order. Current-repo: `- #<N>: <title>`. Cross-repo: `- repo#<N>: <title>` (short form) or `- owner/repo#<N>: <title>` (full form, preferred when owner known).
- **Path B**: read the first entry's title from `context.md ## Issue metadata - title:`; additional issues fetch via `gh issue view <N> --json title --jq .title` (pass `--repo <owner/repo>` for cross-repo). Fetch failure → `- #<N>: (title unavailable)`.
- **Path C** (empty `closes_issues`): write the placeholder:
  ```
  ## Issues
  (none — pending issue creation or NON_GITHUB)
  ```
  Completion backfills `- #<N>: <title>` after `gh issue create`. Placeholder satisfies `assemble-mandatory.sh`'s "heading must be present" invariant.
- `context.md` missing or title line absent → `- #<N>: (title unavailable)`.

## `## Glossary` schema (mandatory heading)

Immediately after `## Issues`. The intent glossary lists only the terms this session adds, deletes, or redefines.

- Write the heading always; leave the body empty when no term changes — no fixed placeholder such as `(none)`.
- Non-empty body: one table with the header `| Term | Category | Operation | Definition |`, a separator row, then one row per change.
- Operation: `add` (a new term), `delete` (remove the term; Definition may be empty), `redefine` (replace the definition of an existing term in the same category).
- Rename: a `delete` row for the old term plus an `add` row for the new one. Category move: a `delete` row in the old category plus an `add` row in the new one.
- A same-category redefinition is one `redefine` row; a `delete` + `add` pair for the same term and category is a BLOCK (`use-redefine`); terms that differ only in case are a heading rename, written as that `delete` + `add` pair.
- A legacy 3-column table (`| Term | Category | Definition |`) is still accepted; every row reads as `add`.
- The `session` category allows `add` only.
- Category values and how to pick one: `rules/docs/glossary.md`.
- Term + Operation must be unique (case-insensitive term) within the table.
- The plan artifact hooks (`hooks/gate-plan-lang.js`, `hooks/check-plan-lang.js`) check this section on every write.

## `## Class members` schema (mandatory)

Appears immediately before `## Accepted Tradeoffs`. Format per member:
```
- <name>: <description> — triage: <MUST | OPTIONAL | NA>
```
Triage enum (exact strings — protocol violation otherwise):
- `triage: MUST` — symmetric change required for class consistency; planner MUST cover.
- `triage: OPTIONAL` — related; planner SHOULD address or explicitly defer in `## Confirmed non-goals`.
- `triage: NA` — sibling exists but orthogonal; out of scope for this task.

No candidates detected → `- (none detected)` (no triage field).

## `## worktrees` schema (optional)

Written when CI-3b collected at least one non-empty worktree path. Omit entirely for single-repo sessions. Format per entry:
```
- repo: <owner/repo>
  worktree_path: <absolute path>
```
