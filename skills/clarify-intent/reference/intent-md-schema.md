# intent.md Schema

Referenced by CI-4. Format rules for `<PLANS_DIR>/<session-id>-intent.md`.

## Section order

1. H1 title
2. `**Title:** <human-readable one-line title>` — data contract read by Path C for `gh issue create --title`.
3. `## Issues` (mandatory — see rules below)
4. Background/Motivation
5. Scope
6. Constraints
7. Interview Log (optional)
8. `## Class members` (mandatory — see schema below)
9. `## Accepted Tradeoffs` (`### <title>` heading + 1-paragraph rationale per entry; empty → write `(none)`) — captures design decisions already settled, used by `extract-mandatory-sections` to suppress re-raised concerns in later codex reviews.
10. `## worktrees` (optional — omit for single-repo sessions; include when CI-3b collected sibling worktree paths)

Language: write body text in `PLAN_LANG` (`$AGENTS_CONFIG_DIR/.env`) when it is a concrete non-English language; heading lines (any level) are exempt. `PLAN_LANG` unset/`any`/`english` → write in English.

## `## Issues` schema (mandatory)

Immediately after the `**Title:**` line, before Background/Motivation. Single SSOT for `closes_issues` — no separate `## closes_issues` section.

- One entry line per issue in `closes_issues`, in order. Current-repo: `- #<N>: <title>`. Cross-repo: `- repo#<N>: <title>` (short form) or `- owner/repo#<N>: <title>` (full form, preferred when owner known).
- **Path B**: read the first entry's title from `context.md ## Issue metadata - title:`; additional issues fetch via `gh issue view <N> --json title --jq .title` (pass `--repo <owner/repo>` for cross-repo). Fetch failure → `- #<N>: (title unavailable)`.
- **Path C** (empty `closes_issues`): write the placeholder:
  ```
  ## Issues
  (none — pending issue creation or NON_GITHUB)
  ```
  Completion backfills `- #<N>: <title>` after `gh issue create`. Placeholder satisfies `assemble-mandatory.sh`'s "heading must be present" invariant.
- `context.md` missing or title line absent → `- #<N>: (title unavailable)`.

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
