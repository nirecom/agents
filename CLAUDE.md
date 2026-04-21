# Global Claude Code Instructions

## Workflow

Create the following as a TodoWrite checklist and work through each step in order.

1. **Research** — Run `/survey-code` and/or `/deep-research`.
   - `/survey-code`: Skip when the change target is already known (single file/function).
   - `/deep-research`: Skip when no external knowledge is needed.
   - If unnecessary: `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"`
2. **Plan** — Run `/make-plan` (planner/reviewer discussion → approval).
   - Skip when: the task is a single-file change AND no design decision is needed.
   - Skipping Research does NOT justify skipping Plan.
   - If unnecessary: `echo "<<WORKFLOW_PLAN_NOT_NEEDED: <reason>>"`
   Run `/review-plan-security` when the plan involves secrets, third-party services, or external input.
3. **Write tests** — **Always write or update tests before modifying source code.** Run `/write-tests`.
   - If unnecessary: `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"`
4. **Code** — Present a diff in chat before calling Edit. Wait for approval.
5. **Run tests & Security review** — Run both in parallel (single response, two tool calls):
   - Bash: run the test suite (PostToolUse hook auto-marks `run_tests` on exit code).
     Manual fallback: `echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"`
   - Agent: `/review-code-security` as a subagent (conditional: external input / secrets /
     third-party integrations). If unnecessary: `echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>"`
6. **Docs** — Run `/update-docs`. Mandatory for every task.
7. **User verification** — Wait for the user to confirm the task is complete.
8. **Commit** — Run `/commit-push`.

## Docs-only Short-circuit

If the staged diff is entirely under `docs/` and all files are `.md`, steps 1–6 are
auto-bypassed — only `user_verification` is required before committing.

## Workflow State Recovery

The main conversation can reset workflow state only when it has enough holistic context
to judge that a reset is genuinely warranted. Skills and subagents must not reset.

```
echo "<<WORKFLOW_RESET_FROM_<step>>>"
```
