# Global Claude Code Instructions

## Workflow

1. **Workflow init** — **Before anything else:** Run `/workflow-init`.
   Routes the session based on GH issue context:
   - `#N` + `intent:clarified` label → skip clarify-intent, proceed to outline planning.
   - `#N` + no label → pre-fill clarify-intent with issue body for a short confirmation interview.
   - No `#N` → run clarify-intent normally; auto-create a tracking issue at completion.
   For docs-only edits skip routing: `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"`.
   Skipping here does NOT authorize skipping clarify-intent or subsequent steps.
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
6. **Run tests & Security review** — Run all in parallel (single response, multiple tool calls):
   - Skill: `/run-tests`
   - Agent: `/review-code-security` as a subagent. If unnecessary: `echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>"`
   - Bash: `review-code-codex --base <merge-base>` for cross-provider adversarial review
     (always parallel, never blocks workflow). Output is shown directly to the user via
     the Bash tool result, so the `## Codex Review: PERFORMED|SKIPPED|FAILED` status line
     is visible without relying on Claude's summary.
   - Bash: `review-skill-size --base <merge-base>` for skill definition size/quality check
     (always parallel, non-blocking; warnings only, never blocks workflow)
7. **Docs** — Run `/update-docs`. Mandatory for every task.
8. **User verification:**
   - **`ENFORCE_WORKTREE=on`:** No action here — proceed to step 9.
   - **`ENFORCE_WORKTREE=off`:** Run `echo "<<WORKFLOW_USER_VERIFIED>>"` immediately;
     set the Bash `description` to explain what the user is approving.
9. **Commit** — Run `/commit-push`.
10. **Cleanup** — Based on the step 3 decision:
    - **worktree:** Run `/worktree-end` (merge + sentinel emit + cleanup). Mandatory; do not skip.
    - **branch:** Confirm PR is created. After the PR is merged (outside this session),
      delete the branch: `git branch -d <name>` then `git push origin --delete <name>`.
    - **main:** Skip.

    After cleanup, read `<session-id>-intent.md`'s `## closes_issues` section.
    If it contains exactly one issue number, run `/issue-close <N>`.
    (`/issue-close` handles the `CLOSED + (none)` state correctly — PR auto-close
    via `closes #N` is the expected trigger for this path.)
    If the section reads `(empty)` or is absent, skip.
    (Multi-issue sessions are not expected. If the list has more than one entry,
    run `/issue-close` for each sequentially — no dependency sorting, no retry.)

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
