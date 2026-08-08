# Global Claude Code Instructions

All work follows [`rules/core-principles.md`](rules/core-principles.md).

## Workflow

Begin file-modifying sessions with `/workflow-init`; skip for read-only investigation.

Steps use prefix `WF-<TYPE>-N`; `WF-CODE-N` = standard implementation. `WF-META-N` = planning-only (meta issues, no worktree).

After each skill completes, run: `node bin/workflow/next-step --session $CLAUDE_SESSION_ID`. Follow `ACTION` / `NEXT_SKILL` / `NEXT_HINT` output — `invoke` means run the named skill immediately without pausing to ask the user (reserve confirmation for `CONFIRM_*` gates, the `USER_VERIFIED` sentinel, and in-skill `AskUserQuestion`), `done` means proceed to session close, `blocked`/`abort` means see `NEXT_HINT` for recovery, `paused` means next-step is deliberately quiet — take no workflow action and continue the user's out-of-workflow work, resuming with `echo "<<WORKFLOW_NEXT_STEP_RESUME: {reason}>>"` when `REASON=next-step-paused` or `echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: {reason}>>"` when `REASON=workflow-off-quiet`. Run `bin/workflow/next-step --list` for the full 15-step plan. Emergency partial reset: `echo "<<WORKFLOW_RESET_FROM_{step}: {reason}>>"` (reason mandatory; marks prior steps complete, resets target step and after to pending).

## Notes

- Skill procedures settle a step and read the next action in one call: `next-step --advance --step <step> --status <status> [--skip-reason <reason>] --next`. `record-skip-judgment` / `record-complexity-and-skip` / `set-workflow-type` support the same `--advance [--next]` pair for their own step. Only pass `--next` when the call is expected to consume the returned `ACTION` block right away; otherwise omit it and proceed to the skill's own next documented step. `--next` never emits an `ACTION=` line when the settled step is not the session's current step (`ADVANCE_SCOPE=not-current-step`) — absence of `ACTION=` means proceed to your own next documented step, not an error.
- Do not use `--permission-mode plan`. Always use default mode for implementation tasks.
- `write-code` is not a tracked `next-step` step — invoke it manually once `write_tests`/`review_tests` complete, before `/run-tests`.
- Workflow state reset is main-conversation only — emit `<<WORKFLOW_RESET_FROM_{step}: {reason}>>` only when holistic context justifies it.
- For docs-only commits that shortcut the workflow, see `rules/docs-only-short-circuit.md`.
- For trivial edits that temporarily suspend workflow enforcement, see `rules/workflow-off.md`.
- For bugs, follow-ups, or next-task findings discovered mid-workflow, see `rules/mid-workflow-findings.md`.
- When working inside the agents repository itself, also consult `docs/agents-repo-dev.md`.
- When you encounter an issue, concern, or unexpected outcome that core-principles + workflow don't resolve, report it: see [rules/supervisor-reporting.md](rules/supervisor-reporting.md).
- For declaring background work so the Stop guard stays quiet, see [rules/stop-guard-exemptions.md](rules/stop-guard-exemptions.md).
