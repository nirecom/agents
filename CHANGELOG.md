## Archived
- [2026](history/2026.md) — 105 entries

### FEATURE: PR #592 (2026-05-27)
Background: feat(#556/#555/#557/#582): replace class-members disposition with triage MUST/OPTIONAL/NA
Changes: `/clarify-intent` class members step now shows Claude's proposed triage for each sibling member (MUST / OPTIONAL / NA with rationale) as a text block, then asks "Accept as-is or Modify?" — replacing the previous multiSelect list.

### FEATURE: PR #591 (2026-05-27)
Background: fix(#519): normalize Git Bash POSIX paths in encode_path_for_claude_projects
Changes: WIP signaling restored on Windows Git Bash environments where `/c/...` POSIX paths previously broke session-id resolution, causing silent failure in `wip-state.sh` even after the #440 fix.

### FEATURE: PR #593 (2026-05-27)
Background: feat(#581): per-context language configuration (PLAN_LANG, ASK_LANG, CONV_LANG)
Changes: doc-append CHANGELOG.md --category FEATURE --subject "Per-context language configuration (.env keys: PLAN_LANG, ASK_LANG, CONV_LANG)" --background "Language of AskUserQuestion prompts and planning artifacts (intent/outline/detail.md) could not be configured independently." --changes "New .env keys: PLAN_LANG (planning artifacts), ASK_LANG (AskUserQuestion), CONV_LANG (main conversation guidance). Existing DOCS_LANG_HISTORY / DOCS_LANG_CHANGELOG_PUBLIC / DOCS_LANG_CHANGELOG_PRIVATE now also readable from .env (fenced-block in rules/language.md still works as fallback). Valid values for all keys: english | japanese | any."

### FEATURE: PR #597 (2026-05-27)
Background: fix(#574/#563): extend show-plan-link to Bash tool; fix confirm-plan guard off-mode bypass
Changes: Plan artifact link now appears in VS Code when `assemble-mandatory.sh` is called via the Bash tool (standard SKILL.md flow) — previously the breadcrumb only fired on Write-tool plan writes. (#574);Path-emission guard now enforces correctly in `CONFIRM_<STEP>=off` sessions — the guard was silently bypassed when confirmation was turned off. (#563)

### FEATURE: PR #605 (2026-05-27)
Background: feat(#598): add CONFIRM_DOCS flag to /update-docs to skip proposal confirmation
Changes: "`CONFIRM_DOCS` flag added to `/update-docs`: set `CONFIRM_DOCS=off` in `.env` to skip the approval prompt and apply docs entries automatically. Proposed content is always shown in the conversation."

### FEATURE: PR #609 (2026-05-27)
Background: feat(#602): PR1 — fix refactor-prompts Windows bug, add review-skill-size --all, worktree-start non-interactive mode
Changes: `/refactor-prompts` now works on Windows: scan output captured in-memory instead of writing to `/tmp/rp-scan.json`;`review-skill-size --all` scans all SKILL.md files regardless of diff (bare invocation unchanged);`worktree-start` supports non-interactive mode via `--task-name`/`--branch-type` args (skips confirmation dialog; idempotent for repeated calls)

### FEATURE: PR #615 (2026-05-29)
Background: fix(#596,#432): unblock /issue-create dispatch + repair sub-issue attach
Changes: Fixed `/issue-create` being blocked from the main worktree when issue body contained git operation keywords like `git commit` (#596).;Fixed `/issue-create` sub-of / make-parent attach failing with HTTP 422 — sub-issues API now uses integer databaseId via `gh api -F` (#432).

### FEATURE: PR #616 (2026-05-29)
Background: feat(#606,#607): add §4 Scenario Sweep to core-principles + sibling-sweep to review tools
Changes: core-principles.md now has 6 sections: §1 SSOT → §2 Elevate Perspective → §3 Orthogonality → §4 Scenario Sweep (new) → §5 Audience-Aware Behavior → §6 Name Reflects Substance. The new §4 Scenario Sweep extends fixes to future class members, not just current siblings.;Review tools (review-code-codex, review-plan-security, review-code-security, review-plan-codex) now include a sibling-sweep step: each reviewer enumerates class members in the diff/plan and flags them MUST / OPTIONAL / NA for the same treatment.

### FEATURE: PR #618 (2026-05-29)
Background: feat(#594): support arbitrary language codes; split DOCS_LANG_HISTORY into PUBLIC/PRIVATE
Changes: **FEATURE: Arbitrary language codes accepted; DOCS_LANG_HISTORY split into PUBLIC/PRIVATE (#594)**

### FEATURE: PR #628 (2026-05-29)
Background: refactor(#619): remove docs-lang fenced-block fallback; consolidate DOCS_LANG_* in .env
Changes: `DOCS_LANG_*` policy is now read exclusively from `.env`; the `docs-lang` fenced block in `rules/language.md` is no longer consulted. The error footer in `check-worktree-notes-lang` now references `.env (DOCS_LANG_HISTORY_*, DOCS_LANG_CHANGELOG_*)` as the policy source.

### FEATURE: PR #627 (2026-05-29)
Background: feat(#603): replace prompt-based codex-review-loop enforcement with exit-code-driven wrapper
Changes: "Codex review loop is now enforced by `bin/run-codex-review-loop` — orchestrators can no longer skip or misparse the verdict. Exit codes (0=approved, 1=revision needed, 2=cap, 3=fallback, 4=broken infrastructure) replace the previous prose-based verdict instructions. (#603)"

### FEATURE: PR #631 (2026-05-29)
Background: feat(#622): record issue-create primary-path findings to WORKTREE_NOTES.md
Changes: `/issue-create` now automatically appends the created (or re-opened) issue to `WORKTREE_NOTES.md` `## RelatedTasks`. The entry carries the `<!-- promoted: #N -->` marker so it appears in the Final Report without a manual triage step. All dispatch outcomes are covered (new, reopen, sub-of, make-parent, sibling). Skipped silently when running from the main worktree.;`worktree-notes-triage list` now filters out already-promoted entries, matching its documented contract. Pre-marked entries written by `worktree-notes-append.js` are never re-promoted by Step 5.5(a.5).

### FEATURE: PR #640 (2026-05-29)
Background: fix(#636): revert issue-close-finalize/SKILL.md to eval pattern
Changes: fix: issue-close-finalize reverted to eval pattern — the tmpfile approach introduced by PR #632 was incompatible with ENFORCE_WORKTREE=on (mktemp blocked from main worktree)

### FEATURE: PR #643 (2026-05-30)
Background: feat(#635): hook approval phrase + direct sentinel emit for PR approval flow
Changes: PR approval flow: the model now emits the `WORKFLOW_USER_VERIFIED` sentinel directly after creating the PR — no more intermediate text reply needed. The permission dialog now shows the PR URL and "Click Allow to approve; click Deny to stop" above the Allow / Deny buttons.

### FEATURE: PR #625 (2026-05-30)
Background: feat(#608): add /session-close skill — Final Report after issue-close-finalize
Changes: Final Report now includes a "Closed Issue Outcomes" section showing per-issue close results (history.md append, issue close, sentinel posting, WIP clear). Final Reports now emit symmetrically on both `ENFORCE_WORKTREE=on` (worktree) and `off` (branch/main) paths via the new `/session-close` skill.


### FEATURE: PR #648 (2026-05-30)
Background: fix(#642): harden worktree-end session-id capture with dual-defense WORKTREE_NOTES.md fallback
Changes: fix: worktree-end no longer picks the wrong session-id after VS Code restart or context compaction — the creating session's id is now persisted durably in WORKTREE_NOTES.md and recovered automatically by both the skill orchestration layer and capture-env.sh itself (#642)

### FEATURE: PR #648 (2026-05-30)
Background: fix(#642): harden worktree-end session-id capture with dual-defense WORKTREE_NOTES.md fallback
Changes: fix: worktree-end no longer picks the wrong session-id after VS Code restart or context compaction — the creating session's id is now persisted durably in WORKTREE_NOTES.md and recovered automatically by both the skill orchestration layer and capture-env.sh itself (#642)

### FEATURE: PR #651 (2026-05-30)
Background: fix(#595): add E2E bypass integration tests and fix git-add WRITE classification
Changes: Fixed: `ISSUE_CLOSE_SKILL=1 git add docs/history.md` and `COMPOSE_DOC_APPEND_SKILL=1 git add CHANGELOG.md` now correctly reach the bypass predicate; previously `git add` was classified as read-only in `bash-write-patterns.js`, causing the bypass check to be skipped

### FEATURE: PR #655 (2026-05-30)
Background: fix(#650): replace broken gh pr list --jq --arg with -H in is_pr_merged
Changes: category=BUGFIX subject="fix(#650): sweep-worktrees now correctly detects merged PRs" changes="Fixed a bug where /sweep-worktrees skipped every zombie worktree because the gh pr list call used an unsupported --jq --arg flag form. Worktrees with merged PRs are now detected and reclaimed as expected."

### FEATURE: feat(#630): extract SKILL.md inline blocks to per-skill scripts/, unify rules/ naming (2026-05-30, 55cd415)
Background: SKILL.md files had inline code blocks for codex-review-loop and assemble-mandatory invocations; rules/ had inconsistent naming. Extractions and renames reduce orchestrator context overhead and enforce the no-inline-code rule.
Changes: SKILL.md inline code blocks extracted to skills/<name>/scripts/ — orchestrators read shorter SKILL.md files with lower context overhead.
rules/ naming unified: docs-convention/ → docs/, test-rules/ → test/, prompt-criteria.md → prompt.md; all cross-references updated.
New rule §1.4 in rules/prompt.md: going-forward, 3+-line fenced code blocks in SKILL.md/rules/agents files must be extracted to skills/<name>/scripts/.

