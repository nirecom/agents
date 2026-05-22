# Global Claude Code Instructions

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
7. **Docs** — Run `/update-docs`. Mandatory. (The skill handles `docs/history.md` via `bin/compose-history-entry` when `closes_issues` is empty; otherwise Step 8.5 covers it.)
8. **User verification:**
   - **`ENFORCE_WORKTREE=on`:** No action here — proceed to step 8.5.
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
   sub-issue gate, posts the pending sentinel, commits the `docs/history.md`
   entry on the feature branch, and updates the parent body if applicable.
   Skip silently when `closes_issues` is empty. Skip entirely when
   `ENFORCE_WORKTREE=off` (the 2-phase split does not apply to direct-main work
   — `/issue-close-finalize` runs the full chain at Step 10b instead).
9. **Commit** — Run `/commit-push`. Pre-flights Phase 1 completion per
   `closes_issues` (aborts if missing) and appends `<!-- issue-close-pr-of: <N> -->`
   markers to the PR body so `find-pr-by-marker.sh` can resolve the merge SHA in
   Phase 2. After the PR is created, display the PR URL in chat so the user can
   confirm it.
10. **Cleanup** — Based on the step 3 decision:
    - **worktree:** Run `/worktree-end` (merge + sentinel emit + cleanup). Mandatory; do not skip.
    - **branch:** Confirm PR is created. After the PR is merged (outside this session),
      delete the branch: `git branch -d <name>` then `git push origin --delete <name>`.
    - **main:** Skip.

10b. **Phase 2 issue close** — After the PR is merged, run
    `/issue-close-finalize --from-session` from the main worktree (reads
    `closes_issues` from the session intent.md and routes to the correct close
    path; skips if empty). Phase 2 is API-only on the normal path: promote the
    sentinel, close the issue, and post the resolved-by + appended sentinels.
    Safe from the main worktree under `ENFORCE_WORKTREE=on`.

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

## Mid-workflow finding capture

While running the workflow — at any point up to and including Step 5 of
`/worktree-end` (Step 5.5 backs up `WORKTREE_NOTES.md`; later findings go to
`/issue-create`) — if you discover a bug unrelated to the current task, a
related follow-up task, or a next-task candidate, append a bullet to the
matching section of `<worktree>/WORKTREE_NOTES.md`:

- `## BugsFound` — defects observed during the workflow
- `## RelatedTasks` — adjacent work to address in a separate session
- `## NextTasks` — follow-ups specific to the current change

Edit `WORKTREE_NOTES.md` directly (worktree directory; gitignored; not subject
to `enforce-worktree`). Replace `- (none)` on first append.
