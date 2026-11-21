---
paths:
  - ".on-demand-only/never-match"
---
<!-- injection: on-demand-only - auto-injection disabled; the owning skill Reads it explicitly. -->

# Mid-Workflow Finding Capture

When you discover a bug unrelated to the current task, a related follow-up, or a next-task candidate while running the workflow:

Capture the finding at once in `<worktree>/WORKTREE_NOTES.md`; a finding that exists only in this session's context is lost when the session ends.
Whether it is filed is decided by the triage rules (`skills/_shared/notes-promotion.md`), not by you at capture time.

Give every finding exactly one of three dispositions:
- fix in this PR — after the fixing commit, record `node "$AGENTS_MAIN_ROOT/bin/worktree-notes-triage.js" dispose "<worktree>/WORKTREE_NOTES.md" <lineNumber> fixed`;
- Known limits — an unfixed `this-pr` finding goes to the PR body's `## Known limits` at promotion;
- file — an `other` finding is filed by the promotion rules; implement it in a separate session via `/workflow-init <N>`.

Mid-workflow issues are NOT added to the current session's `closes_issues` (1 session = 1 issue).
A finding that blocks the current work: ask the user with AskUserQuestion, dialog `mid-workflow-findings.blocking-file`, then run `/issue-create` from the linked worktree on approval.
A `/issue-create` the user types is approved by its own record; the `/issue-create` Mid-workflow gate surfaces this notice before Phase 1.

Do not write agents-repo improvements or findings to `~/.claude/projects/<project-slug>/memory/` — capture them via this rule's path instead.

Promotion: `/worktree-end` Step WE-7 promotes unconverted `WORKTREE_NOTES.md` entries per `skills/_shared/notes-promotion.md`. **Cutoff: Step WE-6** — findings after that go directly to `/issue-create`.

**Append via the CLI** (the path for every `WORKTREE_NOTES.md` write): `node "$AGENTS_MAIN_ROOT/bin/worktree-notes-append.js" --notes-path "<worktree>/WORKTREE_NOTES.md" --section <Section> --title "<one-line finding>" --severity high|medium|low|not-defect --pr-scope this-pr|other [--instance "<observed instance>"] [--loc "<path:line>"] [--test-failure]`.

Triage flags: `BugsFound`, `RelatedTasks` and `NextTasks` require `--severity` and `--pr-scope`; `ManualReminders` rejects them. `--test-failure` requires `--instance`.
Judge severity by `skills/_shared/severity.md` (SSOT); a HIGH claim states its reason there.
Legacy markers `high|low|none` from the old CLI still parse: `none` reads as `not-defect`, and an entry with no marker reads as `medium`.

The CLI owns section routing, `- (none)` replacement, idempotency, and marker generation — do not hand-assemble an entry line.

Manual editing of `WORKTREE_NOTES.md` (gitignored; not subject to `enforce-worktree`) is the fallback when the CLI is unusable — a hand-written entry carries no markers, so it reads as `medium` / `other`.

Sections (the `--section` values):

- `## BugsFound` — defects observed during the workflow
- `## RelatedTasks` — adjacent work implemented in a separate session
- `## NextTasks` — follow-ups specific to the current change
- `## ManualReminders` — actions only the user can perform by hand; surfaced in chat at close, never promoted to an issue
