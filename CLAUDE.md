# Global Claude Code Instructions

All work follows [`rules/core-principles.md`](rules/core-principles.md).

## Workflow

Steps prefix `WF-<TYPE>-N`; `WF-CODE-N` = standard implementation. `WF-TXT-N` and `WF-PLAN-N` reserved. After each skill completes, run `bin/workflow/next-step --session $CLAUDE_SESSION_ID` and follow its `ACTION`/`NEXT_SKILL`/`NEXT_HINT` output.

WF-CODE-1. **Workflow init** — `/workflow-init`. Docs-only: `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"`. Mid-workflow issues: `/issue-create`.
WF-CODE-2. **Plan** — Research (`/survey-code`/`/deep-research`) → `/make-outline-plan` → `/make-detail-plan`. Skip a stage: `echo "<<WORKFLOW_*_NOT_NEEDED: reason>>"`. Add `/review-plan-security` when plan involves secrets or external input.
WF-CODE-3. **Branch/Worktree** — `ENFORCE_WORKTREE=on` (default): `/worktree-start`. `off`: branch or main (see `rules/branch.md`). Record: `echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: <name>|worktree: <path>|main>>"`.
WF-CODE-4. **Write tests & review** — `/write-tests` then `/review-tests`. Skip both: `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: reason>>"`.
WF-CODE-5. **Code** — `/write-code`.
WF-CODE-6. **Run tests & security** — Parallel: `/run-tests`; `/review-code-security` (skip: `WORKFLOW_REVIEW_SECURITY_NOT_NEEDED`); `review-code-codex --base <merge-base> --context "$AGENTS_CONFIG_DIR/rules/core-principles.md"`; `review-skill-size --base <merge-base>`; `review-code-size --base <merge-base>`; `review-env-example --base <merge-base>`; `review-step-numbers --base <merge-base>`; `review-e2e-coverage --base <merge-base>`; `review-bare-python --base <merge-base>`.
WF-CODE-7. **Docs** — `/update-docs`. Mandatory.
WF-CODE-8. **User verification** — `on`: deferred to `/worktree-end` WE-8; do NOT emit `<<WORKFLOW_USER_VERIFIED>>` here. `off`: follow `skills/_shared/user-verified.md`.
WF-CODE-9. **Phase 1 issue close** — `/issue-close-stage <N>` per `closes_issues` from linked worktree. Skip when empty or `ENFORCE_WORKTREE=off`.
WF-CODE-10. **Commit** — `/commit-push`.
WF-CODE-11. **Cleanup** — worktree: `/worktree-end`; branch: delete after merge; main: skip.
WF-CODE-12. **Session close** — `/session-close` from main worktree.

## Notes

- Do not use `--permission-mode plan`. Always use default mode for implementation tasks.
- Workflow state reset is main-conversation only — emit `<<WORKFLOW_RESET_FROM_<step>>>` only when holistic context justifies it.
- For docs-only commits that shortcut the workflow, see `rules/docs-only-short-circuit.md`.
- For trivial edits that temporarily suspend workflow enforcement, see `rules/workflow-off.md`.
- For bugs, follow-ups, or next-task findings discovered mid-workflow, see `rules/mid-workflow-findings.md`.
- When working inside the agents repository itself, also consult `docs/agents-repo-dev.md`.
- When you encounter an issue, concern, or unexpected outcome that core-principles + workflow don't resolve, report it: see [rules/supervisor-reporting.md](rules/supervisor-reporting.md).
