# Global Claude Code Instructions

## Workflow

1. **Clarify intent** — **Before anything else:** Run `/clarify-intent`.
   Skip: `echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: <reason>>"` then proceed to step 2. Skipping here does NOT authorize skipping subsequent steps.
2. **Plan** — Three-stage planning pipeline. Run each stage in order:
   - **2a. Research** — Run `/survey-code` and/or `/deep-research`.
     If unnecessary: `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"`
   - **2b. `/make-outline-plan`** — Propose 2-3 approach options and get user sign-off.
   - **2c. `/make-detail-plan`** — Produce file-level plan via planner/reviewer loop.
   - Skipping Research (2a) does NOT justify skipping the remaining Plan stages.
   - If Plan entirely unnecessary: `echo "<<WORKFLOW_PLAN_NOT_NEEDED: <reason>>"`
   Run `/review-plan-security` when the plan involves secrets, third-party services, or external input.
3. **Branch/Worktree creation** —
   - **`ENFORCE_WORKTREE=on` (default)**: all writes from the main worktree are blocked, regardless of branch. Run `/worktree-start` to create a linked worktree on a feature branch.
     Enforced by `enforce-worktree.js` (PreToolUse) and `pre-commit`.
   - **`ENFORCE_WORKTREE=off`**: main worktree writes allowed. Options: branch-only (`git switch -c <name>`, naming → `rules/branch.md`) or main directly for trivial changes. Consult `rules/branch.md` for branch-vs-main.
   Record: `echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: <name>|worktree: <path>|main>>"`
   (`main` is only valid when `ENFORCE_WORKTREE=off`.)
4. **Write tests** — **Always write or update tests before modifying source code.** Run `/write-tests`.
   - If unnecessary: `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"`
5. **Code** — Present a diff in chat before calling Edit. Wait for approval.
6. **Run tests & Security review** — Start three actions in parallel (single response, multiple tool calls):
   - Agent: `Agent({subagent_type: "test-runner", model: "sonnet", prompt: <see template>})`.
     Test output is absorbed by the subagent; only a structured YAML summary returns to main.
     After ALL three parallel calls return, emit the appropriate sentinel as a separate Bash call:
     - `status: pass` → `echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>"`
     - `status: fail | timeout | runner-error` → `echo "<<WORKFLOW_MARK_STEP_run_tests_pending>>"`,
       then surface the agent's `summary` / `failing_tests` / `log_tail` to the user.
     The failure-path sentinel is mandatory — without it, a previously-complete `run_tests`
     state from an earlier run would let a now-failing build through the commit gate.
     Prompt template:
     ```
     Run the project test suite.
     Test command: <explicit command, or "auto-detect">
     Working directory: <cwd or explicit path>
     Timeout: 120s
     Return the structured YAML summary per your output contract.
     ```
     Model selection: default `sonnet`. Escalate to `opus` only when the test surface is
     unusually large or failure-summary parsing demands architectural reasoning.
     Direct Bash test runs still work — PostToolUse hook (workflow-run-tests.js) auto-marks
     based on exit code, keeping backward compatibility.
   - Agent: `/review-code-security` as a subagent. If unnecessary: `echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>"`
   - Bash: `review-code-codex --base <merge-base>` for cross-provider adversarial review
     (always parallel, never blocks workflow). Output is shown directly to the user via
     the Bash tool result, so the `## Codex Review: PERFORMED|SKIPPED|FAILED` status line
     is visible without relying on Claude's summary.
7. **Docs** — Run `/update-docs`. Mandatory for every task.
8. **User verification** — Run `echo "<<WORKFLOW_USER_VERIFIED>>"` immediately; set the Bash `description` to explain what the user is approving.
9. **Commit** — Run `/commit-push`.
10. **Cleanup** — Based on the step 3 decision:
    - **worktree:** Run `/worktree-end` (merge + cleanup). Mandatory; do not skip.
    - **branch:** Confirm PR is created. After the PR is merged (outside this session),
      delete the branch: `git branch -d <name>` then `git push origin --delete <name>`.
    - **main:** Skip.

## Plan Mode Incompatibility

`--permission-mode plan` is incompatible with this workflow — Skill tool invocations
are restricted in that mode. Always use default mode for implementation tasks.

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
