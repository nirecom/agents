---
paths:
  - ".on-demand-only/never-match"
---
<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->

# Mid-Workflow Finding Capture

When you discover a bug unrelated to the current task, a related follow-up, or a next-task candidate while running the workflow:

**Primary path** — invoke `/issue-create` immediately from the linked worktree. Mid-workflow issues are NOT added to the current session's `closes_issues` (1 session = 1 issue). Address them in a separate session via `/workflow-init <N>`. The `/issue-create` Mid-workflow gate surfaces this notice before Phase 1.

Defer the implementation to a separate session; never defer the filing itself. A finding that exists only in this session's context is lost when the session ends.

**Fallback path** — use `<worktree>/WORKTREE_NOTES.md` only when:
- Non-interactive session (`claude -p`, subagent, `/loop`), OR
- Non-GitHub remote (`bin/is-github-dotcom-remote` returns non-zero), OR
- User explicitly defers.

Fallback recovery: `/worktree-end` Step WE-11 promotes unconverted `WORKTREE_NOTES.md` entries to issues, per `skills/_shared/notes-promotion.md`. **Cutoff: Step WE-8** — findings after that go directly to `/issue-create`.

**Append via the CLI** (primary path for every `WORKTREE_NOTES.md` write): `node "$AGENTS_CONFIG_DIR/bin/worktree-notes-append.js" --notes-path "<worktree>/WORKTREE_NOTES.md" --section <Section> --title "<one-line finding>" [--severity high|low|none]`.

The CLI owns section routing, `- (none)` replacement, idempotency, and marker generation — do not hand-assemble an entry line.

Severity: `--section BugsFound` requires `--severity`; every other section rejects it. Only `high` survives verbatim in the Final Report; `low` and `none` compress to a title line and produce identical output. Judge `high` by the three conditions in the `skills/issue-create/SKILL.md` "Label policy" (SSOT).

Manual editing of `WORKTREE_NOTES.md` (gitignored; not subject to `enforce-worktree`) is the fallback when the CLI is unusable — a hand-written entry carries no severity tag, so it always compresses to a title line in the Final Report.

Sections (the `--section` values):

- `## BugsFound` — defects observed during the workflow
- `## RelatedTasks` — adjacent work implemented in a separate session; filed in this one
- `## NextTasks` — follow-ups specific to the current change
- `## ManualReminders` — actions only the user can perform by hand; surfaced in chat at close, never promoted to an issue
