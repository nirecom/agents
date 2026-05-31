# Mid-Workflow Finding Capture

When you discover a bug unrelated to the current task, a related follow-up, or a next-task candidate while running the workflow:

**Primary path** — invoke `/issue-create` immediately from the linked worktree. Mid-workflow issues are NOT added to the current session's `closes_issues` (1 session = 1 issue). Address them in a separate session via `/workflow-init <N>`. The `/issue-create` Mid-workflow gate surfaces this notice before Phase 1.

**Fallback path** — use `<worktree>/WORKTREE_NOTES.md` only when:
- Non-interactive session (`claude -p`, subagent, `/loop`), OR
- Non-GitHub remote (`bin/is-github-dotcom-remote` returns non-zero), OR
- User explicitly defers.

Fallback recovery: `/worktree-end` Step 5.5(a.5) promotes unconverted `WORKTREE_NOTES.md` entries to issues. **Cutoff: Step 5** — findings after that go directly to `/issue-create`.

Fallback sections (edit `WORKTREE_NOTES.md` directly; gitignored; not subject to `enforce-worktree`). Replace `- (none)` on first append:

- `## BugsFound` — defects observed during the workflow
- `## RelatedTasks` — adjacent work to address in a separate session
- `## NextTasks` — follow-ups specific to the current change
