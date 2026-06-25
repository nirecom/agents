# Global Claude Code Instructions

All work follows [`rules/core-principles.md`](rules/core-principles.md).

## Workflow

Steps use prefix `WF-<TYPE>-N`; `WF-CODE-N` = standard implementation. `WF-META-N` = planning-only (meta issues, no worktree).

After each skill completes, consult the oracle: `node bin/workflow/next-step --session $CLAUDE_SESSION_ID`. Follow `ACTION` / `NEXT_SKILL` / `NEXT_HINT` output — `invoke` means run the named skill, `done` means proceed to session close, `blocked`/`abort` means see `NEXT_HINT` for recovery. Run `bin/workflow/next-step --list` for the full 14-step plan. Emergency partial reset: `echo "<<WORKFLOW_RESET_FROM_<step>>>"` (marks prior steps complete, resets target step and after to pending).

## Notes

- Do not use `--permission-mode plan`. Always use default mode for implementation tasks.
- Workflow state reset is main-conversation only — emit `<<WORKFLOW_RESET_FROM_<step>>>` only when holistic context justifies it.
- For docs-only commits that shortcut the workflow, see `rules/docs-only-short-circuit.md`.
- For trivial edits that temporarily suspend workflow enforcement, see `rules/workflow-off.md`.
- For bugs, follow-ups, or next-task findings discovered mid-workflow, see `rules/mid-workflow-findings.md`.
- When working inside the agents repository itself, also consult `docs/agents-repo-dev.md`.
- When you encounter an issue, concern, or unexpected outcome that core-principles + workflow don't resolve, report it: see [rules/supervisor-reporting.md](rules/supervisor-reporting.md).
