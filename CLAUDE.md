# Global Claude Code Instructions

## Workflow

Steps below assume `ENFORCE_WORKTREE=on` (default). For `=off` differences, see `rules/worktree.md`.

1. **Workflow init** — Run `/workflow-init` first (routes by GH issue context; see `skills/workflow-init/SKILL.md`). Mid-workflow follow-up issues: `/issue-create`. Docs-only edits may skip via `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` (does not authorize skipping later steps).
2. **Plan** — Three-stage pipeline; read `rules/core-principles.md` first.
   - **2a. Research** — `/survey-code` and/or `/deep-research`. Skip: `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"`
   - **2b.** `/make-outline-plan` — 2-3 approaches, user sign-off.
   - **2c.** `/make-detail-plan` — file-level plan via planner/reviewer loop.
   - Skipping 2a does NOT justify skipping 2b/2c. Skip whole Plan: `echo "<<WORKFLOW_PLAN_NOT_NEEDED: <reason>>"`
   - Run `/review-plan-security` when the plan involves secrets, third-party services, or external input.
3. **Branch/Worktree** — Run `/worktree-start` to create a linked worktree on a feature branch (main-worktree writes are blocked by `enforce-worktree.js` + `pre-commit`). Record: `echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: <name>|worktree: <path>|main>>"` (`main` valid only when `ENFORCE_WORKTREE=off`).
4. **Write tests** — Always before source changes. Run `/write-tests`. Skip: `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"`
5. **Code** — Call Edit directly (no diff approval required under `=on`).
6. **Run tests & Security review** — All in parallel (single response, multiple tool calls):
   - `/run-tests`
   - `/review-code-security` subagent (skip: `echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>"`)
   - `review-code-codex --base <merge-base> --context "$AGENTS_CONFIG_DIR/rules/core-principles.md"` (non-blocking; status line shown directly via Bash result)
   - `review-skill-size --base <merge-base>` (non-blocking, warnings only)
7. **Docs** — Skip `/update-docs`; docs review deferred to PR review.
8. **User verification** — No action under `=on`; proceed to 8.5.
8.5. **Phase 1 issue close** — For each N in session `closes_issues` (parsed from `${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/<session-id>-intent.md`), run `/issue-close-stage <N>` from the linked worktree (sub-issue gate, pending sentinel, `docs/history.md` commit, parent body update). Skip silently when empty.
9. **Commit** — Run `/commit-push` (pre-flights Phase 1 completion; appends `<!-- issue-close-pr-of: <N> -->` to PR body for `find-pr-by-marker.sh`). Display PR URL after creation.
10. **Cleanup** — Per step 3 decision: **worktree** → `/worktree-end` (mandatory); **branch/main** → see `rules/branch.md`.
10b. **Phase 2 issue close** — After PR merge, run `/issue-close-finalize --from-session` from the main worktree (API-only on normal path; safe under `=on`). See `rules/github-issues.md`.

## Plan Mode Incompatibility

`--permission-mode plan` is incompatible with this workflow (Skill tool restricted). Use default mode.

## Docs-only Short-circuit

If every staged file is in the human-facing docs allowlist — any `.md` under `docs/`, or root `README.md` / `CHANGELOG.md` / `CONTRIBUTING.md` / `LICENSE.md` — steps 1–6 are auto-bypassed; only `user_verification` is required before commit. Root `CLAUDE.md`, `SKILL.md`, and subdirectory `README.md` are behavior/prompt code and do NOT qualify.

## Workflow State Recovery

Only the main conversation may reset workflow state (skills/subagents must not): `echo "<<WORKFLOW_RESET_FROM_<step>>>"`

## Mid-workflow finding capture

At any point up to Step 5 of `/worktree-end` (Step 5.5 backs up `WORKTREE_NOTES.md` — later findings go to `/issue-create`), append unrelated bugs / follow-up tasks / next-task candidates to `<worktree>/WORKTREE_NOTES.md`:

- `## BugsFound` — defects observed during the workflow
- `## RelatedTasks` — adjacent work for a separate session
- `## NextTasks` — follow-ups specific to the current change

Edit `WORKTREE_NOTES.md` directly (gitignored; not subject to `enforce-worktree`). Replace `- (none)` on first append.
