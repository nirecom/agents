# Global Claude Code Instructions

All work follows [`rules/core-principles.md`](rules/core-principles.md).

## Workflow

1. **Workflow init** — **Before anything else:** Run `/workflow-init` (routes by GH issue context; see `skills/workflow-init/SKILL.md`).
   Mid-workflow follow-up issues: use `/issue-create`.
   For docs-only edits skip routing: `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"`.
   Skipping here does NOT authorize skipping clarify-intent or subsequent steps.
2. **Plan** — Three-stage planning pipeline. Run each stage in order.
   Read `rules/core-principles.md` first — it governs every plan stage.
   - **2a. Research** — Run `/survey-code` and/or `/deep-research`.
     If unnecessary: `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"`
   - **2b. `/make-outline-plan`** — Propose 2-3 approach options and get user sign-off.
     If a single obvious approach exists: `echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: <reason>>"`
   - **2c. `/make-detail-plan`** — Produce file-level plan via planner/reviewer loop.
     If file-level changes are already settled in outline: `echo "<<WORKFLOW_DETAIL_NOT_NEEDED: <reason>>"`
   - Skipping Research (2a) does NOT justify skipping the remaining Plan stages.
   - `WORKFLOW_PLAN_NOT_NEEDED` was removed in #485. Emit both per-stage sentinels to reproduce the old bulk-skip.
   Run `/review-plan-security` when the plan involves secrets, third-party services, or external input.
3. **Branch/Worktree creation** —
   - **`ENFORCE_WORKTREE=on` (default)**: all writes from the main worktree are blocked, regardless of branch. Run `/worktree-start` to create a linked worktree on a feature branch.
     Enforced by `enforce-worktree.js` (PreToolUse) and `pre-commit`.
   - **`ENFORCE_WORKTREE=off`**: main worktree writes allowed. Options: branch-only (`git switch -c <name>`, naming → `rules/branch.md`) or main directly for trivial changes. Consult `rules/branch.md` for branch-vs-main.
   Record: `echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: <name>|worktree: <path>|main>>"`
   (`main` is only valid when `ENFORCE_WORKTREE=off`.)
4. **Write tests** — **Always write or update tests before modifying source code.** Run `/write-tests`.
   - If unnecessary: `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"`
5. **Code** — Run `/write-code`. The skill delegates editing and lint/typecheck/self-repair to a subagent. Behavior is identical under `ENFORCE_WORKTREE=on` and `off` — the Edit permission dialog is the sole approval surface.
6. **Run tests & Security review** — Run all in parallel (single response, multiple tool calls):
   - Skill: `/run-tests`
   - Agent: `/review-code-security` as a subagent. If unnecessary: `echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>"`
   - Bash: `review-code-codex --base <merge-base> --context "$AGENTS_CONFIG_DIR/rules/core-principles.md"` for cross-provider adversarial review
     (always parallel, never blocks workflow). Output is shown directly to the user via
     the Bash tool result, so the `## Codex Review: PERFORMED|SKIPPED|FAILED` status line
     is visible without relying on Claude's summary.
   - Bash: `review-skill-size --base <merge-base>` for skill definition size/quality check
     (always parallel, non-blocking; warnings only, never blocks workflow)
   - Bash: `review-code-size --base <merge-base>` for JS/SH/PY file size check
     (always parallel, non-blocking; advisory only, never blocks workflow)
7. **Docs** —
   - **`ENFORCE_WORKTREE=on`:** Run `/update-docs`. Mandatory — the skill stages bullets into `WORKTREE_NOTES.md` `## History Notes` / `## Changelog Notes` instead of writing `docs/history.md` / `CHANGELOG.md` directly. `bin/compose-doc-append-entry` consumes those sections during `/worktree-end` Step 6i (post-merge, main worktree).
   - **`ENFORCE_WORKTREE=off`:** Run `/update-docs`. Mandatory.
8. **User verification:**
   - **`ENFORCE_WORKTREE=on`:** No action here — proceed to step 8.5. **Do NOT emit `<<WORKFLOW_USER_VERIFIED>>` here.** Emission is deferred to `/worktree-end` Step 4 (after the PR is open and merge is imminent). Premature emission from a linked worktree without an open PR is blocked by workflow-gate (see issue #577).
   - **`ENFORCE_WORKTREE=off`:** If staged files and an open PR URL are both absent,
     skip this step. Otherwise follow `skills/_shared/user-verified.md`: emit
     `echo "<<WORKFLOW_USER_VERIFIED: <reason>>>"` (the `: <reason>` is mandatory
     and becomes part of the on-disk audit record), and set the Bash
     `description` to explain what the user is approving. The PreToolUse hook
     surfaces staged files (and an open PR URL, if any) above the permission
     dialog.
8.5. **Phase 1 issue close** — For each issue N in the session's `closes_issues`
   (parsed from `${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/<session-id>-intent.md`),
   run `/issue-close-stage <N>` from the linked worktree. Phase 1 performs the
   sub-issue gate, posts the pending sentinel and promotes it to appended (history.md is written by Phase 2 from the main worktree via ISSUE_CLOSE_SKILL bypass), and updates the parent body if applicable.
   Skip silently when `closes_issues` is empty. Skip entirely when
   `ENFORCE_WORKTREE=off` (the 2-phase split does not apply to direct-main work
   — `/issue-close-finalize` runs the full chain at Step 10b instead).
9. **Commit** — Run `/commit-push`. Pre-flights Phase 1 completion per
   `closes_issues` (aborts if missing) and appends `<!-- issue-close-pr-of: <N> -->`
   markers to the PR body so `find-pr-by-marker.sh` can resolve the merge SHA in
   Phase 2. After the PR is created, do not narrate the PR URL in chat — the
   `<<WORKFLOW_USER_VERIFIED>>` sentinel (emitted from `/worktree-end` Step 4 or,
   in `ENFORCE_WORKTREE=off`, Step 8) triggers `show-user-verified-context.js`,
   which surfaces the PR URL and approval instruction above the permission dialog.
   See `skills/_shared/user-verified.md`.
10. **Cleanup** — Based on the step 3 decision:
    - **worktree:** Run `/worktree-end`. Normal path: merge → sentinel emit → worktree removal. `/worktree-end` no longer emits the Final Report — that responsibility moved to `/session-close` (Step 10b). If removal fails (e.g. Windows CWD lock), treat the step as complete and proceed to Step 10b — the residual worktree is reclaimed by the next `/sweep-worktrees` run.
      (Step 6i always runs `bin/compose-doc-append-entry`; when `closes_issues` is non-empty, `--skip-history` is added so only `CHANGELOG.md` is written — `docs/history.md` was already committed by Phase 1/2.)
    - **branch:** Confirm PR is created. After the PR is merged (outside this session),
      delete the branch: `git branch -d <name>` then `git push origin --delete <name>`.
    - **main:** Skip.

10b. **Session close** — Run `/session-close` from the main worktree.
    `/session-close` handles Phase 2 issue close (via `/issue-close-finalize`)
    plus Final Report emit for both `ENFORCE_WORKTREE=on` (consumes the env
    JSON written by `/worktree-end` Step 5.5) and `off` (builds a minimal env
    JSON from PR data). Safe when `closes_issues` is empty — outcome renders as
    `- (none)` and the Final Report still emits.

## Notes

- Do not use `--permission-mode plan`. Always use default mode for implementation tasks.
- Workflow state reset is main-conversation only — emit `<<WORKFLOW_RESET_FROM_<step>>>` only when holistic context justifies it.
- For docs-only commits that shortcut the workflow, see `rules/docs-only-short-circuit.md`.
- For trivial edits that temporarily suspend workflow enforcement, see `rules/workflow-off.md`.
- For bugs, follow-ups, or next-task findings discovered mid-workflow, see `rules/mid-workflow-findings.md`.
- When working inside the agents repository itself, also consult `docs/agents-repo-dev.md`.
- EM Supervisor reporting (passive observation from skills/agents): see [rules/supervisor-reporting.md](rules/supervisor-reporting.md).
