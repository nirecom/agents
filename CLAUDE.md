# Global Claude Code Instructions

## Workflow

Create the following as a TodoWrite checklist and work through each step in order.

1. **Research** — Run `/survey-code` and/or `/deep-research`.
   - `/survey-code`: Skip when the change target is already known (single file/function).
   - `/deep-research`: Skip when no external knowledge is needed.
   - If unnecessary: `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"`
2. **Plan** — Three-stage planning pipeline. Run each stage in order:
   - **2a. `/clarify-intent`** — Interview the user to lock in requirements, motivation, scope,
     and non-goals. Mandatory; cannot be skipped within the Plan step.
   - **2b. `/design-approach`** — Propose 2-3 high-level approaches via approach-designer +
     approach-reviewer subagents, then get user sign-off. Skip when only one approach is
     obviously viable (`SINGLE_APPROACH_JUSTIFIED` from approach-designer).
   - **2c. `/make-detail-plan`** — Produce file-level plan via planner/reviewer loop.
     Skip when: single-file change AND no design decision is needed.
   - Skipping `clarify-intent` within Plan requires `<<WORKFLOW_PLAN_NOT_NEEDED>>` — implicit skip is not allowed.
   - Skipping Research does NOT justify skipping Plan.
   - If Plan entirely unnecessary: `echo "<<WORKFLOW_PLAN_NOT_NEEDED: <reason>>"`
   Run `/review-plan-security` when the plan involves secrets, third-party services, or external input.
3. **Write tests** — **Always write or update tests before modifying source code.** Run `/write-tests`.
   - If unnecessary: `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"`
4. **Code** — Present a diff in chat before calling Edit. Wait for approval.
5. **Run tests & Security review** — Run all in parallel (single response, multiple tool calls):
   - Bash: run the test suite (PostToolUse hook auto-marks `run_tests` on exit code).
     Manual fallback: `echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"`
   - Agent: `/review-code-security` as a subagent (conditional: external input / secrets /
     third-party integrations). If unnecessary: `echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>"`
   - Bash: `review-code-codex --base <merge-base>` for cross-provider adversarial review
     (always parallel, never blocks workflow). Output is shown directly to the user via
     the Bash tool result, so the `## Codex Review: PERFORMED|SKIPPED|FAILED` status line
     is visible without relying on Claude's summary.
6. **Docs** — Run `/update-docs`. Mandatory for every task.
7. **User verification** — Wait for the user to confirm the task is complete.
8. **Commit** — Run `/commit-push`.

## Docs-only Short-circuit

If every staged file matches the human-facing docs allowlist — any `.md` under `docs/`,
or one of the root-level files `README.md`, `CHANGELOG.md`, `CONTRIBUTING.md`,
`LICENSE.md` — steps 1–6 are auto-bypassed. Only `user_verification` is required before
committing. Root `CLAUDE.md`, `SKILL.md`, and subdirectory `README.md` are behavior/prompt
code and do NOT qualify.

## Workflow State Recovery

The main conversation can reset workflow state only when it has enough holistic context
to judge that a reset is genuinely warranted. Skills and subagents must not reset.

```
echo "<<WORKFLOW_RESET_FROM_<step>>>"
```
