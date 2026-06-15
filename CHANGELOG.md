## Archived
- [2026](history/2026.md) — 10

### FEATURE: PR #687 (2026-05-31)
Background: refactor(#672): enforce-worktree positive-allow redesign
Changes: enforce-worktree redesigned to positive-allow: linked worktrees can write freely; main worktree writes are blocked without env-var bypass ceremony (#672). gh issue create now requires a linked worktree — /issue-create guides you to /worktree-start if needed (#600). gh pr merge and gh api PATCH from linked worktrees no longer false-positive blocked (#527). /issue-close-finalize and /worktree-end commit docs to main via GitHub REST API — no local main-worktree write needed.

### FEATURE: PR #698 (2026-05-31)
Background: fix(#685): stop symlink-repair loop firing on every shell start
Changes: category: BUGFIX

### FEATURE: PR #699 (2026-05-31)
Background: refactor(#253): migrate path-based deny rules to PreToolUse hooks
Changes: History and changelog files are now protected by a PreToolUse hook (`block-history-direct.js`) that works across all Claude Code clients; direct edits are blocked while `doc-append` remains the authorised write path;Shell config files (`~/.bashrc`, `~/.zshrc`, `~/.profile` etc.) are now protected by a PreToolUse hook (`block-shell-config.js`) covering both direct tool writes and Bash redirects;Removed 41 redundant `settings.json` deny rules that were already handled by PreToolUse hooks, eliminating duplicate permission definitions;Default model changed from `claude-opus-4-7` to `claude-sonnet-4-6`

### FEATURE: PR #704 (2026-06-01)
Background: feat(#689): PR-scoped test selection + obsolete test retirement
Changes: `/run-tests` now selects only tests relevant to the current PR (Tier 1 filename-stem match + Tier 2 LLM semantic match via `# Tests:`/`# Tags:` frontmatter) instead of running all 230+ tests — prevents the multi-hour hang from session #673. `tests/run-all.sh --all` is the explicit opt-in for the full suite. Non-doc changes with zero matched tests escalate to the user instead of auto-running everything.

### FEATURE: PR #709 (2026-06-01)
Background: feat(#674): strengthen outline-planner with cross-component structural integrity check
Changes: "outline-planner now surfaces cross-component structural integrity risks in each proposed approach — component contract changes, dependency direction violations, and responsibility coverage gaps are required fields. The SINGLE_APPROACH_JUSTIFIED output includes this analysis as well."

### FEATURE: PR #710 (2026-06-01)
Background: fix(#626,#700): replace JSONL scan with flag+transcript handshake in stop-final-report-guard
Changes: Final Report verification now reliably forces verbatim paste regardless of how many turns follow the Final Report, and blocks when the renderer output appeared only in a Bash tool result without being pasted (fixes #611 silent-pass and #700 tool-result bypass)

### FEATURE: PR #729 (2026-06-02)
Background: feat(#712): add review-code-size + fix review-skill-size 3-source union
Changes: Step 6 now runs `review-code-size --base <merge-base>` in parallel, warning when JS/SH/PY files exceed 300 lines (warn) or 500 lines (hard limit). Both `review-code-size` and `review-skill-size` now detect staged, unstaged, and untracked file changes in addition to committed diffs.

### FEATURE: PR #728 (2026-06-03)
Background: fix(#724): sync-labels.sh three-way label status (created/updated/already-exists)
Changes: `sync-labels.sh` now shows per-label status: `(created)` for new labels, `(updated)` for changed labels, and `(already exists)` for unchanged ones — replacing the previous unconditional recreation. The final summary shows `N created, M updated, K already-exists / T total`.

### FEATURE: PR #736 (2026-06-03)
Background: fix(#730): replace gh api -f content= with --input to avoid ARG_MAX on large files
Changes: fix: large-file commits via `/worktree-end` Step 6h (`docs/history.md` ≥ ~25 KB) no longer fail with "Argument list too long" on Windows (#730)

### FEATURE: PR #737 (2026-06-03)
Background: feat(#723): add MCP filesystem server for repo-scoped codex reviewer file access
Changes: The codex reviewer can now read actual source files from the current repo on demand via a new MCP filesystem server (`bin/mcp-fs-server.js`). The server is REPO_ROOT-confined with credential protection (`.env*`, private keys, `.git/`, `.ssh/` blocked). Set `CODEX_MCP_FS=off` to disable.

### FEATURE: PR #744 (2026-06-04)
Background: fix(#654): add built-in .worktree-backup/** exclusion in enforce-worktree
Changes: Fixed: `/worktree-end` Step 5 backup copy to `.worktree-backup/` now always succeeds when Bash CWD has reset to the main worktree — enforce-worktree now has `.worktree-backup/**` as a built-in exclude pattern (non-overridable via `ENFORCE_WORKTREE_EXCLUDE`).

### FEATURE: PR #747 (2026-06-04)
Background: fix(#742): mcp-fs-server defensive hardening — file-size cap, binary probe, repo-root validation
Changes: category=SECURITY subject="fix(#742): mcp-fs-server defensive hardening" background="Security hardening of the MCP filesystem server and its callers (fix(#742), PR #737 follow-up)" changes="bin/mcp-fs-server.js now rejects files larger than 5 MB and binary files detected within the first 8 KB, preventing OOM on oversized inputs. --repo-root passed to review-plan-codex and run-codex-review-loop is now validated as an existing directory before use (review-plan-codex: exit 0 + FAILED; run-codex-review-loop: exit 4). Set MCP_FS_DEBUG=1 to write [mcp-fs] deny/serve events to stderr; when LOG_DIR is also set, review-plan-codex persists the MCP stderr log to ${LOG_DIR}/detail-plan-codex-stderr.log. .env.example: new MCP section documents CODEX_MCP_FS and MCP_FS_DEBUG."

### FEATURE: PR #749 (2026-06-04)
Background: fix(#746): replace --ask-for-approval with --full-auto in review-plan-codex MCP_OVERRIDES
Changes: Fixed: codex plan/outline reviews now run correctly via codex (not Claude fallback); codex v0.125.0 removed `--ask-for-approval`, now replaced with `--full-auto`

### FEATURE: PR #753 (2026-06-04)
Background: fix(#733): relax doc-append date-order check, align rotation sort helper, fix idempotency grep
Changes: `doc-append` now accepts entries whose date is up to 7 days before the last entry's date, so concurrent sessions closing the same issue no longer fail when their merge dates differ by a few days.;`/issue-reconcile` backfill no longer produces duplicate history entries when `#N` appears in the subject line of an existing entry (e.g. `### Fix #N: ...`) rather than only in the trailing parenthetical.

### BUGFIX: PR #754 (2026-06-04)
Background: fix(#740): extend enforce-worktree allowlist for worktree-end cleanup ops
Changes: Fixed 5 `enforce-worktree` allowlist gaps that blocked `/worktree-end` cleanup: Step 5 backup cp, Step 6c worktree remove, Step 6d worktree prune, Step 6g pre-pull stash, and `feat/` branch deletion are now correctly permitted when `WORKTREE_END_SKILL=1` prefix is present

### FEATURE: PR #752 (2026-06-04)
Background: feat(#741): size-gate — SKILL.md 200-line HARD block, code HARD block, file-split rule
Changes: bin/review-skill-size and bin/review-code-size now exit 1 (block the workflow) when HARD size limits are exceeded in diff mode (>200 lines for SKILL.md, >500 lines for code files). Previously both checks were advisory (always exit 0).;New rule rules/coding/file-split.md documents the two file-split patterns: code files use a sibling folder + dispatch shim; SKILL.md files extract procedures to scripts/ or bin/ while keeping SKILL.md as the prompt entrypoint.

### FEATURE: PR #762 (2026-06-04)
Background: fix(#634): guard capture-env.sh against BACKUP_DIR=(none) and missing dir
Changes: Fixed: ending a worktree session without files to back up (or choosing "discard") no longer silently drops `docs/history.md` and `CHANGELOG.md` entries (#634)

### FEATURE: PR #764 (2026-06-05)
Background: feat(#756): session-dedup — CLOSED issue detection + issue-create survey expansion
Changes: Added CLOSED-issue detection to workflow-init, clarify-intent, and issue-create to prevent duplicate work when parallel sessions merge the same issue simultaneously.;`issue-create` duplicate survey now scans up to 50 keyword matches plus all open issues from the past 30 days, reducing duplicate ticket creation in multi-session setups.

### FEATURE: PR #766 (2026-06-05)
Background: fix: 3 workflow-blocking hook false-positives (#670, #686, #659)
Changes: Fixed false PLAN_LANG=japanese violation: the `(none — pending issue creation or NON_GITHUB)` placeholder written by Path C clarify-intent is now exempted from English-run detection.;Fixed `/commit-push` pre-flight incorrectly blocking when the issue was already closed before Phase 1 ran (e.g. via PR `closes #N` auto-close).;Fixed `gh issue create` from the main worktree being blocked by `enforce-worktree` when the issue body (as a `BODY='...'` shell variable) contained write-pattern tokens like `rm` or `mv`.

### FEATURE: PR #768 (2026-06-05)
Background: fix(#765): remove vestigial COMPOSE_DOC_APPEND_SKILL=1 prefix from doc-append-worker
Changes: category: BUGFIX | subject: Fix unnecessary ENFORCE_WORKTREE_OFF prompts during doc-append-entry compose | background: doc-append-worker triggered spurious ENFORCE_WORKTREE_OFF requests due to a vestigial env-var prefix | changes: Removed the prefix; doc-append-worker now uses the bash-script form that enforce-worktree.js already allows without any env-var bypass

### FEATURE: PR #769 (2026-06-06)
Background: feat(#647): priority-hierarchy SSOT — planner rejection protocol for upstream-approved decisions
Changes: Planning loop reviewers can no longer force the planner to override an already-approved intent or outline decision — the planner now formally rejects review concerns that contradict the approved scope, preventing the multi-round drift pattern previously seen during make-detail-plan.

### FEATURE: PR #732 (2026-06-06)
Background: feat(#690,#692): consolidate Step 6h docs-write; fix classify() git false-positive
Changes: `worktree-end` Step 6h now writes both `docs/history.md` and `CHANGELOG.md` from `WORKTREE_NOTES.md` in a single step; Phase 2 Step E (synthesis fallback) removed from the issue-close workflow.;Fixed false-positive in the worktree write guard: `grep`/`rg`/`echo`/`printf` commands containing quoted strings like `"git push"` or `"git commit"` are no longer blocked.

### FEATURE: PR #770 (2026-06-06)
Background: feat(#638,#722): admin_close_path + meta cascade + Group: prefix enforcement
Changes: `issue-close-finalize` now auto-closes meta/group parent issues when all sub-issues are done — no PR or Phase 1 sentinel required (admin_close_path route).

### FEATURE: PR #755 (2026-06-06)
Background: feat(#228): add EM Supervisor Layer 1 structural hook checks + supervisor-state.json schema
Changes: EM Supervisor Layer 1: passive observation layer for skills and agents to report findings (categories: intent/outline/detail/workflow/code/test/security/performance/env/other; severity: error/warning/notice); findings written atomically to per-session supervisor-state.json via bin/supervisor-report CLI; no hooks, no workflow intervention in S-1.

### FEATURE: PR #773 (2026-06-06)
Background: fix(#683): skip header-only sections in migrate-todo.sh
Changes: `migrate-repo` no longer creates spurious GitHub issues for `docs/todo.md` sections that contain only a section header with no task lines. Empty sections are now skipped with a `SKIP: empty section` log line, and the migration summary reports how many sections were skipped vs created.

### FEATURE: PR #775 (2026-06-06)
Background: feat(#771): abolish Final Report renderer; LLM-direct emission + 10-heading stop-hook guard
Changes: Final Report (/session-close Step 4) now requires all 10 section headings in your reply; missing headings or unsubstituted `<TOKEN>` placeholders block the turn and re-prompt with a specific list.

### FEATURE: PR #779 (2026-06-06)
Background: feat(#613,#614): shrink SKILL.md to ≤100 lines + rename steps to skill-prefixed labels (WI/WE/ICF/MDP)
Changes: fix: `block-history-direct.js` hook now correctly unblocks edits to `rules/docs/history.md` (rules file); previously, any file named `history.md` regardless of directory was blocked

### FEATURE: PR #780 (2026-06-06)
Background: feat(#719): EM Supervisor S-2 — Layer 2 semi-realtime JD monitoring + ScheduleWakeup handshake
Changes: EM Supervisor now performs Layer 2 semantic JD-checklist analysis automatically. After 5 minutes of tool activity, a ScheduleWakeup is scheduled; on wakeup the main conversation reviews intent alignment, scope drift, non-goal violations, tacit knowledge continuity, and §3/§4/§5 perspective against plan artifacts and recent findings. Layer 2 verdicts surface as `additionalContext` advisories at each tool use and Stop boundary; `cumulative_severity=error` blocks the turn via the Stop hook.

### FEATURE: PR #781 (2026-06-06)
Background: feat(#772): new-repo bootstrap path for ENFORCE_WORKTREE=on
Changes: New-repo bootstrap: `/worktree-end` now auto-detects a brand-new GitHub repo (no default branch) and pushes the initial commit directly to `main` without a PR, enabling the full ENFORCE_WORKTREE=on workflow from day one.;Codex review timeout: configurable via `CODEX_TIMEOUT_SECS` in `.env` (default 300 s, raised from 180 s); documented in `.env.example`.

### FEATURE: PR #782 (2026-06-06)
Background: ux(#774): auto-backup gitignored state without confirmation prompt
Changes: `/worktree-end` Step WE-8 no longer prompts "Back up, discard, or abort?" — gitignored state is backed up automatically when the inventory is non-empty, and silently skipped when the worktree has no gitignored files.

### FEATURE: PR #783 (2026-06-06)
Background: fix(#778): remove redundant WORKTREE_END_SKILL=1 prefix; tighten --force guard for git worktree remove
Changes: fix: `worktree-end` WE-14 (`git worktree remove`) and WE-16 (`git worktree prune`) no longer require a `WORKTREE_END_SKILL=1` prefix — the hook allowed these commands unconditionally all along. `rules/workflow-off.md` gains a "Sanctioned-command false-block recovery" section: retry without a prefix before disabling enforcement session-wide.

### FEATURE: PR #785 (2026-06-06)
Background: fix(#719): add systemMessage to supervisor-guard.js error-level block output
Changes: EM Supervisor Layer 2 error blocks now show a direct notification in the Claude Code UI (via systemMessage), not just Claude's mediated response.

### FEATURE: PR #784 (2026-06-06)
Background: fix(#546): normalizeCwd + single-spawn in show-plan-link.js
Changes: When multiple VS Code windows are open, plan files (intent/outline/detail) now open in the correct window. Two root causes fixed: Windows Git Bash path normalization (`/c/git/agents` → correct URI) and a timing race in the previous two-step spawn. Note: VS Code 1.121 users may still need to click the breadcrumb manually (known VS Code 1.121 regression; fixed in 1.122+).

### FEATURE: PR #787 (2026-06-07)
Background: fix(#525,#526,#416): hooks triple fix — orphan-CWD tests, workflow-mark signalFatal, sentinel echo classify
Changes: fix(#526): WORKFLOW_MARK_STEP_* handlers now hard-fail (exit 2) when sessionId cannot be resolved, instead of silently skipping the step record. Affected sentinels: MARK_STEP, *_NOT_NEEDED (6 families), USER_VERIFIED, BRANCHING_COMPLETE, CLARIFY_INTENT_COMPLETE. The commit gate now surfaces the failure immediately rather than allowing a phantom step completion.

### BUGFIX: PR #791 (2026-06-07)
Background: fix(#579,#681,#682): migrate-repo robustness + workflow-init reopen Status reset
Changes: workflow-init reopen no longer re-triggers Projects v2 board auto-close (#579): ensure-board-card.sh now resets card Status from Done to In Progress before any board mutation on reopened issues.;migrate-repo Steps 4 and 5 now fail loudly when backfill scripts exit non-zero (#682): re-run with --from-step 4 or --from-step 5 to resume after fixing the underlying error.

### FEATURE: PR #788 (2026-06-07)
Background: fix(#776,#748,#777): exit-4 counter reset + ledger-absent recovery + doc step ref
Changes: Review loop now recovers cleanly from a missing concern-ID ledger at round 2 (auto-downgrade to round 1 with warning) instead of getting stuck; the round counter also resets on fatal errors so retries start fresh.

### FEATURE: PR #790 (2026-06-07)
Background: fix(#786): suppress PR-bundling question in multi-issue sessions
Changes: Multi-issue sessions no longer prompt "bundle into one PR?": the 1-PR-per-session rule is now enforced authoritatively in the planning pipeline instead of relying on emergent model behavior.

### FEATURE: PR #794 (2026-06-07)
Background: feat(#792): implement /sweep-branches sub-skill (remote + local merged-branch cleanup)
Changes: `/sweep --apply` now also cleans up merged-but-undeleted remote and local branches via the new `/sweep-branches` sub-skill.

### FEATURE: PR #801 (2026-06-07)
Background: fix(block-credentials): two-component needle + 4 new families + extraLiteralRoots symmetry (#536,#537,#538,#539)
Changes: block-credentials hook now protects 4 additional credential families (gcloud SDK, HashiCorp Vault, Cargo/crates.io, 1Password CLI); eliminates false-positive blocking of unrelated `~/.config/*` paths (e.g. `~/.config/nvim/**`); extends `/root/<family>` coverage to all 22 protected families (rootful Docker/CI contexts).

### FEATURE: PR #803 (2026-06-07)
Background: fix(#514,#515,#566): bash-write-patterns + strip-quoted-args + enforce-worktree hook fixes
Changes: Fix false classification: write operations hidden inside DQ-quoted `$(...)` or backtick substitutions now correctly block from the main worktree (#514);Fix false classification: quoted command words (`"rm"`, `'cp'`) at command position now correctly classify as write; argument-position quoted verbs no longer false-positive (#515);Fix scope detection: `bash -c` probe with `cd` in the worktree guard now correctly identifies the cd target as the repo root for scope checking (#566)

### FEATURE: PR #804 (2026-06-07)
Background: fix(#793,#458): expand $HOME/~/WORKFLOW_PLANS_DIR in bash redirect targets
Changes: Fixed: bash redirections targeting paths outside the repository (e.g., `$HOME/.workflow-plans/...`, `~/...`, `$WORKFLOW_PLANS_DIR/...`) are now correctly allowed from the main worktree instead of being blocked by `enforce-worktree`

### FEATURE: PR #812 (2026-06-07)
Background: fix(#589,#675,#798): wip-state rc=2 escalation + meta WIP skip + meta_pending_subs triage + all-N label check
Changes: #589: WIP tracking failure (`wip-state.sh` session-id resolution error) now shows a prompt — you can abort the session rather than silently proceeding with no WIP fingerprint.;#675: Running `/issue-close-finalize` on a meta parent with open sub-issues no longer errors; the parent is quietly left open and will auto-close when the last sub-issue closes.;#798: In multi-issue sessions, all issues (not just the primary) are now checked for the `intent:clarified` label — a missing label on a related issue now correctly triggers re-clarification.

### FEATURE: PR #813 (2026-06-07)
Background: feat(#806): rename CLAUDE.md workflow steps to WF-CODE-N prefix
Changes: CLAUDE.md workflow steps are now labeled `WF-CODE-N` (e.g. `WF-CODE-5` for **Code**, `WF-CODE-9` for **Phase 1 issue close**). The new prefix distinguishes top-level steps from skill-internal step IDs (WI-, WE-, ICF-, MDP-) and reserves namespace for future workflow types (`WF-TXT-N`, `WF-PLAN-N`).

### FEATURE: PR #814 (2026-06-08)
Background: docs: trim CLAUDE.md verbose sections + add prompt brevity criteria
Changes: CLAUDE.md trimmed: workflow steps WF-CODE-5/7/8/9/10/11/12 are shorter; rely on skill names for self-documentation.;New prompt-quality criteria in `rules/prompt.md`: every-token-counts brevity (§1.4), restraint on "see issue" pointers (§2.3), and no post-invocation skill explanations (§2.4).

### FEATURE: PR #816 (2026-06-08)
Background: fix(#802): block interpreter-wrapper bypass of isAllowedWorktreeCommand
Changes: Security fix: main-worktree write enforcement now blocks interpreter wrappers (`bash -c '...'`, `sh -c '...'`, etc., including `WORKTREE_END_SKILL=1 bash -c '...'`) that previously slipped past the chaining detector when chaining operators were hidden inside a single-quoted body. Direct `git worktree add/remove/prune` commands (including quoted paths) remain allowed.

### FEATURE: PR #817 (2026-06-08)
Background: feat(#808,#809,#810): sweep series enhancements — --delete-no-pr, empty-parent sweep, /sweep-plans
Changes: `/sweep-branches` now detects branches with no associated PR and can remove them (`--delete-no-pr`) after verifying all commits are reachable from origin; dry-run output accurately predicts which branches will be deleted; branches with open or unknown-state PRs are never touched;`/sweep-worktrees` now reclaims empty task-name parent directories (e.g. `~/git/worktrees/my-task/` left behind after all worktrees inside are removed); verified empty and not referenced by any repo's worktree registry before deletion;New `/sweep-plans` sub-skill reclaims stale `~/.workflow-plans/` session artifacts (intent.md, outline.md, detail.md, drafts/) older than `SWEEP_AGE_DAYS` (default 30 days); groups by session-id prefix and re-checks for recent activity before deleting to avoid removing in-progress sessions

### FEATURE: PR #824 (2026-06-09)
Background: fix(#815): restore confirm-plan UX hooks omitted from PR #767 squash-merge
Changes: **confirm-plan UX is now functional**: at each planning checkpoint (intent, outline, detail), the plan file opens in VS Code and an Allow/Deny permission dialog appears. After `gh pr create`, the PR URL opens in your browser automatically. These features were announced in PR #767 but their hook implementation was accidentally omitted from the squash-merge commit — this release delivers the actual functionality.

### FEATURE: PR #835 (2026-06-10)
Background: feat(#679): migrate-repo AskUserQuestion canary gates + tty-bypass-resistant pre-flight ack
Changes: `/migrate-repo` canary confirmation prompts now use native `AskUserQuestion` dialogs instead of repeated Skill re-invocations, preventing automation bypass. Direct shell callers must prefix `MIGRATE_ACK_EXISTING_ISSUES=1` when the target repo already has issues.

### FEATURE: PR #837 (2026-06-10)
Background: fix(#826): init layer2.next_check_at in appendFinding() + add supervisor-report directives to hotspot skills
Changes: **EM Supervisor Layer 2 triage now fires reliably**: `appendFinding()` initializes the Layer 2 check schedule on every successful finding (including duplicates), so the supervisor Stop hook can wake up and assess accumulated findings instead of staying dormant indefinitely.;Five skills (`/worktree-end`, `/issue-close-finalize`, `/make-detail-plan`, `/write-code`, `/run-tests`) now include a supervisor-report reminder, improving observation coverage across high-incident workflow paths.

### FEATURE: PR #836 (2026-06-10)
Background: fix(#820,#822,#821,#823): enforce-worktree sibling-predicate hardening — interpreter-wrapper + RCE-flag guards
Changes: The enforce-worktree hook now blocks interpreter-wrapper commands (`bash -c 'git push ...'`, `/bin/bash -c '...'`, `env bash -c '...'`) and RCE-class git flags (`-c core.sshCommand=...`, `--upload-pack=...`, `--receive-pack=...`) in the push, merge, and cleanup allow predicates. Previously only `isAllowedWorktreeCommand` (PR #816) had this protection; all sibling predicates are now hardened to the same level.

### FEATURE: PR #840 (2026-06-11)
Background: feat(#708): add meta-label guard to parent-body-update.sh
Changes: Meta-labeled parent issues are no longer updated with checkbox state when a sub-issue closes. Use GitHub's native sub-issue progress UI to track sub-issue completion.

### FEATURE: PR #843 (2026-06-12)
Background: fix(#829): widen sweep-plans regex for epoch-PID and empty-SID prefixes; add compose-doc-append-entry cleanup trap
Changes: fix: `sweep-plans` now correctly removes staging files with unix-epoch-PID or empty session-id prefixes that were previously silently skipped; `compose-doc-append-entry` no longer leaks staging files on SIGINT or early exit

### FEATURE: PR #844 (2026-06-12)
Background: fix(#825): allow compose-doc-append-entry invocation from main worktree
Changes: Fix: `compose-doc-append-entry` can now be invoked from the main worktree during `/worktree-end` Step WE-20 without being blocked by `enforce-worktree.js` (#825).

### FEATURE: PR #845 (2026-06-12)
Background: feat(#833): E2E QA gap — verification gate + L1/L2/L3 policy + Test gap: field
Changes: `bin/check-verification-gate.sh` (new): risk-category classifier fires a targeted verification question before the final PR-approval dialog when staged files touch pwsh-required paths, hook registrations, skills, or installer scripts — zero friction on unrelated PRs.;`doc-append --test-gap TEXT`: new flag records what test was missing on BUGFIX entries; `doc-append` warns to stderr when `--category BUGFIX` is used without `--test-gap`.;`rules/test.md`: new L1/L2/L3 test-layer policy section with closest-to-action verification principle and long-term L3 aspiration targets.;`review_tests` workflow step (new): mandatory gate after `/write-tests` — the commit gate blocks until `/review-tests` emits a pass sentinel with a staged-tests fingerprint token; re-editing tests after a passing review automatically invalidates the gate (stale-token detection); skip propagates symmetrically from `WORKFLOW_WRITE_TESTS_NOT_NEEDED`.

### FEATURE: PR #849 (2026-06-12)
Background: fix(#842): co-emission directive + workflow-mark.js structural fallback + .env-aware CONFIRM_*
Changes: Fixed: Plan-confirmation dialogs (CONFIRM_INTENT, CONFIRM_OUTLINE, CONFIRM_DETAIL) no longer stall after the Allow click. A new PostToolUse handler in workflow-mark.js injects the next-step hint automatically, so the workflow advances on its own.;Fixed: CONFIRM_*=off set in $AGENTS_CONFIG_DIR/.env is now honored by the confirmation hook even when not shell-exported.

### FEATURE: PR #851 (2026-06-12)
Background: feat(#846): add layered settings.json drift prevention (post-merge/checkout hooks + session-start backstop)
Changes: Session-start now warns when `~/.claude/settings.json` is missing entries from the base config — run `node install/assemble-settings.js` to fix.;Git hooks (`post-merge`, `post-checkout`) auto-reassemble `~/.claude/settings.json` when base settings change, preventing stale permission entries that stall workflow sessions.

### BUGFIX: PR #850 (2026-06-12)
Background: fix(#834): migrate-repo TOCTOU pre-flight gate — Option γ Layer P/C + preview-and-capture.sh
Changes: **migrate-repo**: Fixed TOCTOU race in the existing-issues pre-flight gate — external issues created between dry-run review and live migration start are now detected and abort the run, preserving the "early issue numbers = migration history" chronology invariant.

### FEATURE: PR #841 (2026-06-13)
Background: feat(#831): L1 reporting coverage — supervisor-emit facade + hook auto-report + sid auto-resolve
Changes: `supervisor-report --session-id` is now optional: auto-resolves from WORKTREE_NOTES.md or env when omitted; hooks (enforce-worktree, workflow-gate, enforce-issue-close, enforce-override-handlers) now auto-report block and sentinel events to the supervisor state file without manual invocation

### FEATURE: PR #854 (2026-06-13)
Background: fix(#739): generalize enforce-worktree exclusion model for sequenced commands
Changes: `/worktree-end` Step 5 backup and Step 6g pre-pull stash no longer blocked by `enforce-worktree.js`: `mkdir -p .worktree-backup/x && cp ...` sequenced commands and env-prefix variable cp destinations are now correctly allowed through the exclusion-path fast-path.

### FEATURE: PR #859 (2026-06-13)
Background: fix(#842): simplify CONFIRM_NEXT_STEP_HINT table to single-sentence directives
Changes: CONFIRM plan approval (Allow click on CONFIRM_INTENT / CONFIRM_OUTLINE / CONFIRM_DETAIL) now reliably continues the workflow: next-step hints simplified to one-sentence directives so the LLM acts immediately instead of treating them as background information.

### FEATURE: PR #863 (2026-06-15)
Background: fix(#861): inject CONV_LANG into session-start + post-compact additionalContext
Changes: `CONV_LANG` now works: setting `CONV_LANG=japanese` (or any language) in `.env` instructs Claude to respond in that language. The setting previously had no effect; it now injects a one-line language directive into session context at startup and after each compact. Set to `english` or leave unset to disable.
