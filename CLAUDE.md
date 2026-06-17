# Global Claude Code Instructions

All work follows [`rules/core-principles.md`](rules/core-principles.md).

## Workflow

Steps use a two-stage prefix: `WF-<TYPE>-N`. `WF-CODE-N` covers standard implementation sessions (this file). `WF-TXT-N` (text-creation workflows) and `WF-PLAN-N` (planning-only workflows) are reserved for future types.

WF-CODE-1. **Workflow init** — **Before anything else:** Run `/workflow-init`.
   Mid-workflow follow-up issues: use `/issue-create`.
   For docs-only edits skip routing: `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"`.
WF-CODE-2. **Plan** — Three-stage planning pipeline. Run each stage in order.
   Read `rules/core-principles.md` first — it governs every plan stage.
   - **WF-CODE-2a. Research** — Run `/survey-code` and/or `/deep-research`.
     If unnecessary: `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>"`
   - **WF-CODE-2b. `/make-outline-plan`** — Propose 2-3 approach options and get user sign-off.
     If a single obvious approach exists: `echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: <reason>>"`
   - **WF-CODE-2c. `/make-detail-plan`** — Produce file-level plan via planner/reviewer loop.
     If file-level changes are already settled in outline: `echo "<<WORKFLOW_DETAIL_NOT_NEEDED: <reason>>"`
   - Skipping Research (2a) does NOT justify skipping the remaining Plan stages.
   - `WORKFLOW_PLAN_NOT_NEEDED` was removed in #485. Emit both per-stage sentinels to reproduce the old bulk-skip.
   Run `/review-plan-security` when the plan involves secrets, third-party services, or external input.
WF-CODE-3. **Branch/Worktree creation** —
   - **`ENFORCE_WORKTREE=on` (default)**: all writes from the main worktree are blocked, regardless of branch. Run `/worktree-start` to create a linked worktree on a feature branch.
     Enforced by `enforce-worktree.js` (PreToolUse) and `pre-commit`.
   - **`ENFORCE_WORKTREE=off`**: main worktree writes allowed. Options: branch-only (`git switch -c <name>`, naming → `rules/branch.md`) or main directly for trivial changes. Consult `rules/branch.md` for branch-vs-main.
   Record: `echo "<<WORKFLOW_BRANCHING_COMPLETE: branch: <name>|worktree: <path>|main>>"`
   (`main` is only valid when `ENFORCE_WORKTREE=off`.)
WF-CODE-4. **Write tests & review** — **Always write or update tests before modifying source code.** Run `/write-tests`, then immediately run `/review-tests`.
   - `/review-tests` emits `<<WORKFLOW_MARK_STEP_review_tests_complete>>` on pass (adequate coverage) or `<<WORKFLOW_REVIEW_TESTS_WARNINGS: <summary>>>` on gaps.
   - On gaps: address in `/write-tests`, then re-run `/review-tests` until it passes.
   - If both are unnecessary: `echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>>"` (symmetrically waives both the write and review gates).
WF-CODE-5. **Code** — Run `/write-code`.
WF-CODE-6. **Run tests & Security review** — Run all in parallel (single response, multiple tool calls):
   - Skill: `/run-tests`
   - Agent: `/review-code-security` as a subagent. If unnecessary: `echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>"`
   - Bash: `review-code-codex --base <merge-base> --context "$AGENTS_CONFIG_DIR/rules/core-principles.md"` for cross-provider adversarial review
     (always parallel, never blocks workflow). Output is shown directly to the user via
     the Bash tool result, so the `## Codex Review: PERFORMED|SKIPPED|FAILED` status line
     is visible without relying on Claude's summary.
   - Bash: `review-skill-size --base <merge-base>` for skill definition size/quality check
     (always parallel; HARD >200 lines blocks via exit 1; WARN/INFO advisory)
   - Bash: `review-code-size --base <merge-base>` for JS/SH/PY file size check
     (always parallel; HARD >500 lines blocks via exit 1; WARN/INFO advisory)
   - Bash: `review-env-example --base <merge-base>` for .env.example comment-style check
     (always parallel; HARD violations block via exit 1; WARN/INFO advisory)
WF-CODE-7. **Docs** — Run `/update-docs`. Mandatory.
WF-CODE-8. **User verification:**
   - **`ENFORCE_WORKTREE=on`:** No action here — proceed to WF-CODE-9. **Do NOT emit `<<WORKFLOW_USER_VERIFIED>>` here.** Emission is deferred to `/worktree-end` Step WE-7.
   - **`ENFORCE_WORKTREE=off`:** If staged files and an open PR URL are both absent, skip this step. Otherwise follow `skills/_shared/user-verified.md`: emit `echo "<<WORKFLOW_USER_VERIFIED: <reason>>>"` (`: <reason>` mandatory, becomes part of the audit record), and set the Bash `description` to explain what the user is approving.
WF-CODE-9. **Phase 1 issue close** — For each N in `closes_issues`, run `/issue-close-stage <N>` from the linked worktree.
   Skip silently when `closes_issues` is empty. Skip entirely when `ENFORCE_WORKTREE=off` (`/issue-close-finalize` runs the full chain at WF-CODE-12 instead).
WF-CODE-10. **Commit** — Run `/commit-push`. After the PR is created, do not narrate the PR URL in chat — the Bash tool result already shows it. In on-mode, `<<WORKFLOW_USER_VERIFIED>>` is emitted later by /worktree-end Step WE-7; in off-mode, /commit-push emits it directly.
WF-CODE-11. **Cleanup** — Based on the WF-CODE-3 decision:
    - **worktree:** Run `/worktree-end`. If removal fails (Windows CWD lock), proceed to WF-CODE-12 — reclaimed by next `/sweep-worktrees`.
    - **branch:** Confirm PR is created. After merge: `git branch -d <name>` then `git push origin --delete <name>`.
    - **main:** Skip.

WF-CODE-12. **Session close** — Run `/session-close` from the main worktree.

## Notes

- Do not use `--permission-mode plan`. Always use default mode for implementation tasks.
- Workflow state reset is main-conversation only — emit `<<WORKFLOW_RESET_FROM_<step>>>` only when holistic context justifies it.
- For docs-only commits that shortcut the workflow, see `rules/docs-only-short-circuit.md`.
- For trivial edits that temporarily suspend workflow enforcement, see `rules/workflow-off.md`.
- For bugs, follow-ups, or next-task findings discovered mid-workflow, see `rules/mid-workflow-findings.md`.
- When working inside the agents repository itself, also consult `docs/agents-repo-dev.md`.
- When you encounter an issue, concern, or unexpected outcome that core-principles + workflow don't resolve, report it: see [rules/supervisor-reporting.md](rules/supervisor-reporting.md).
