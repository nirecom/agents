# Global Claude Code Instructions

All work follows [`rules/core-principles.md`](rules/core-principles.md).

## Workflow

Begin file-modifying sessions with `/workflow-init`; skip for read-only investigation.

Steps use prefix `WF-<TYPE>-N`; `WF-CODE-N` = standard implementation. `WF-META-N` = planning-only (meta issues, no worktree).

After each skill completes, run: `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --session $CLAUDE_CODE_SESSION_ID`. Follow `ACTION` / `NEXT_SKILL` / `NEXT_HINT` output — `invoke` means run the named skill immediately without pausing to ask the user (reserve confirmation for `CONFIRM_*` gates, the `USER_VERIFIED` dialog that `/get-release-approval` issues, and in-skill `AskUserQuestion`), `done` means proceed to session close, `blocked`/`abort` means see `NEXT_HINT` for recovery, `paused` means next-step is deliberately quiet — take no workflow action and continue the user's out-of-workflow work, resuming with `echo "<<WORKFLOW_NEXT_STEP_RESUME: {reason}>>"` when `REASON=next-step-paused` or `echo "<<WORKFLOW_ENFORCE_WORKFLOW_ON: {reason}>>"` when `REASON=workflow-off-quiet`. Run `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --list` for the full step plan. Emergency partial reset: `echo "<<WORKFLOW_RESET_FROM_{step}: {reason}>>"` (reason mandatory; marks prior steps complete, resets target step and after to pending).

## Notes

- Skill procedures settle a step and read the next action in one call: `next-step --advance --step <step> --complete|--skipped|--pending [--skip-reason <reason>] --next`.
  - `record-skip-judgment` / `set-deliverable-type` / `set-workflow-type` support the same `--advance [--next]` pair for their own step.
  - Pass `--next` only when the call will consume the returned `ACTION` block immediately; otherwise omit it and proceed to the skill's own next documented step.
  - `--next` emits no `ACTION=` line when the settled step is not the session's current step (`ADVANCE_SCOPE=not-current-step`) — treat a missing `ACTION=` as "proceed to your own next step," not an error.
- Do not use `--permission-mode plan`. Always use default mode for implementation tasks.
- Workflow state reset is main-conversation only — emit `<<WORKFLOW_RESET_FROM_{step}: {reason}>>` only when holistic context justifies it.
- Not auto-injected — Read each before the work it governs:
  - `rules/github-issues.md` — any issue or PR operation.
  - `rules/architecture-principles.md` — designing or changing a mechanism, guard, gate, or check.
  - `rules/branch.md` — naming a branch or recording branching.
  - `rules/worktree.md` — creating, entering, or removing a worktree.
  - `rules/ops.md` — any destructive or system-state-changing operation.
  - `rules/test.md` — writing, reviewing, or running tests.
  - `rules/coding.md` — writing or editing code.
  - `rules/docs.md` — writing or updating documentation.
  - `rules/mid-workflow-findings.md` — bugs, follow-ups, or next-task findings discovered mid-workflow.
- For trivial edits that temporarily suspend workflow enforcement, see `rules/workflow-off.md` (when it applies) and `/enforce-workflow-off` (how).
- When working inside the agents repository itself, also consult `docs/agents-repo-dev.md`.
- When you encounter an issue, concern, or unexpected outcome that core-principles + workflow don't resolve, report it: [rules/supervisor-reporting.md](rules/supervisor-reporting.md) says when, `/supervisor-report` does it.
- Asked where a plan is: run `node "$AGENTS_MAIN_ROOT/bin/plan-link" --stage <stage>` and write its output as-is in the response.
- `write-code` is not a tracked `next-step` step — invoke it manually once `write_tests`/`review_tests` complete, before `/run-tests`.
- For keeping the Stop guard quiet during long-running work — automatic while a delegated step is in flight, `NEXT_STEP_PAUSE` otherwise — see [rules/stop-guard-exemptions.md](rules/stop-guard-exemptions.md).
