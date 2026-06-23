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

### FEATURE: PR #864 (2026-06-15)
Background: fix(#416): narrow UNSAFE_REASON_CHARS to 3-char DQ expansion set
Changes: `WORKFLOW_BRANCHING_COMPLETE` and other sentinel echoes with `|`, `;`, `(`, `)`, or `\` in the reason text no longer trigger a false write-classification; the canonical `branch:...|worktree:...|main` format and Windows backslash paths now classify as read and pass through the worktree guard correctly.

### FEATURE: PR #862 (2026-06-15)
Background: fix(#573): upgrade extractRmTargets to quote-aware tokenizer
Changes: Fix: `rm` of non-repo paths with quoted arguments (e.g., memory directory files) from the main worktree now allowed. Previously, any `rm` command with quoted arguments was unconditionally blocked even when the target was outside the repository.

### FEATURE: PR #865 (2026-06-16)
Background: fix(#853): fix 11 stale assertions across 3 test files
Changes: BUGFIX: 3 test files on main had stale assertions; all 11 failures are fixed (CI green restored)

### FEATURE: PR #873 (2026-06-16)
Background: fix(#857): convert EM Supervisor Layer 2 to Stop-hook block
Changes: EM Supervisor Layer 2 is now actually invoked: a sentinel hang (C1) or escape-hatch use (C2) at any Stop triggers a `decision:block`, forcing inline L2 review. The previous ScheduleWakeup advisory was a no-op in normal sessions and has been removed.

### FEATURE: PR #874 (2026-06-16)
Background: feat(#832): auto-accept class member triage, add MUST→OPTIONAL→NA sort
Changes: category=FEATURE subject="#832: class-members-proposal: auto-accept triage" background="class member triage proposal no longer pauses for user confirmation at the intent stage" changes="clarify-intent now auto-accepts the class member triage proposal (MUST/OPTIONAL/NA) and presents it sorted by priority (MUST → OPTIONAL → NA). The 'Accept / Modify?' question is removed; triage values can still be adjusted by planners at the outline and detail stages."

### FEATURE: PR #875 (2026-06-16)
Background: fix(#842): enforce CONFIRM continuation via Stop hook Layer 2
Changes: CONFIRM plan approval (Allow click on CONFIRM_INTENT / CONFIRM_OUTLINE / CONFIRM_DETAIL) now reliably continues the workflow: when the model emits only the CONFIRM sentinel without the required follow-up Skill, the Stop hook detects the missing action and forces the model to restart the turn with the correct next step.

### FEATURE: PR #877 (2026-06-16)
Background: fix(#852): allow git merge/rebase/cherry-pick --abort/--continue/--skip from main worktree
Changes: `git merge --abort`, `git rebase --abort/--continue/--skip`, and `git cherry-pick --abort/--continue/--skip` from the main worktree are no longer blocked by the worktree enforcement hook when run without a `-C` flag

### FEATURE: PR #880 (2026-06-16)
Background: fix(#868): enhance issue-create Phase 2 survey — parallel symptom-token search, Pass 3 widened, inspect cap 25, Verdict Rubric, regression row
Changes: `/issue-create`: now detects same-symptom regressions (issues closed for any reason — merged, won't-fix, manual) and routes to `reopen` instead of creating a duplicate; parallel symptom-token search runs unconditionally in all 3 passes, improving recall for issues described with different vocabulary; candidate inspection cap raised from ~10 to 25 with a new Verdict Rubric that uses symptom-match and scope-overlap as primary signals and treats age as a tie-break rather than a filter

### FEATURE: PR #895 (2026-06-16)
Background: PR #895 merged on 2026-06-16.
Changes: make-outline-plan: selecting "Pass all approaches to make-detail-plan without selecting" in Step 7 no longer triggers a redundant confirmation dialog before proceeding to detail planning.

### BUGFIX: PR #896 (2026-06-17)
Background: fix(#884): add workflow-init prohibition to supervisor post-diagnosis output
Changes: Fix: After L2 Supervisor diagnosis, the model no longer incorrectly prompts to start a new `/workflow-init` session — it returns control to the user instead.

### FEATURE: PR #899 (2026-06-17)
Background: fix(#891): add l2_phase lifecycle enum to supervisor state; gate-yield before Final Report
Changes: **EM Supervisor**: L2 review now runs at most once per session and fires before the Final Report rather than after it; post-session findings no longer re-trigger L2 blocks.

### FEATURE: PR #900 (2026-06-17)
Background: fix(#883): supervisor dual-identifier model — separate CC UUID (sid) from workflow session ID (wsid)
Changes: **Fix:** EM Supervisor Layer 2 now correctly identifies plan artifacts when CC session UUID differs from workflow session ID (date-fallback sessions). Silent wrong-scope reviews are replaced by explicit `Workflow session ID: UNAVAILABLE` degradation with a warning finding.

### FEATURE: PR #904 (2026-06-17)
Background: fix(#842): extend Layer 2 to CONFIRM_PR_CREATED; fix marker early-exit; SSOT PR URL regex
Changes: After clicking Allow on a "PR created" confirmation dialog, `<<WORKFLOW_CONFIRM_PR_CREATED>>` now reliably triggers the next workflow step (worktree-end on `ENFORCE_WORKTREE=on`, `<<WORKFLOW_USER_VERIFIED>>` on `off`), matching the behavior of the INTENT/OUTLINE/DETAIL confirmation sentinels

### FEATURE: PR #906 (2026-06-17)
Background: fix(#879,#892,#891): rename C2 label, add post-Final-Report L2 guard, Phase 4 dispatch detection
Changes: L2 block-reason label updated from "C2 escape-hatch use" to "C2 scheduled-review" — reflects the actual trigger condition (any non-null next_check_at, not only escape-hatch commands).;Post-Final-Report L2 scheduling suppressed: findings written after session-close Step 2A no longer arm next_check_at, preventing stale L2 reviews in the next session.;EM Supervisor JD checklist gains a Phase 4 dispatch detection rule, reducing false-positive misclassification of legitimate /issue-create invocations as Phase 1-3 bypasses.

### FEATURE: PR #910 (2026-06-17)
Background: fix(#726): assemble-mandatory.sh Bash hook not firing when called via SKILL.md wrapper scripts
Changes: show-plan-link.js now fires correctly on Bash-tool assemble-mandatory.sh calls; VS Code plan preview and breadcrumb appear automatically after make-outline-plan and make-detail-plan assembly steps

### FEATURE: PR #916 (2026-06-17)
Background: refactor(#902): rename supervisor layer2 field next_check_at → l2_armed_at
Changes: Supervisor layer2 CLI flags renamed: `--next-check-at` → `--l2-armed-at`, `--clear-next-check-at` → `--clear-l2-armed-at`. State field renamed from `next_check_at` to `l2_armed_at`; existing session state files are ephemeral and require no migration.

### FEATURE: PR #918 (2026-06-17)
Background: fix(#897): CONV_LANG subagent compliance — settings.json language field + SubagentStart hook + per-agent dynamic fallback
Changes: Fixed: supervisor subagent and planning agents now respect CONV_LANG setting. New `SubagentStart` hook (`hooks/subagent-start.js`) injects the language directive into each subagent's context; `settings.json` `"language"` field adds a framework-level first layer. Previously, all subagents emitted English regardless of `CONV_LANG=japanese`.

### FEATURE: PR #919 (2026-06-17)
Background: feat(#885): supervisor accuracy (Axis A) — Layer 1 finding schema: env context + co-block correlation
Changes: **EM Supervisor**: Layer 1 findings now record CWD, git-root resolution result, and a `co_blocked_by` field when two hooks simultaneously block the same command. Layer 2 root-cause analysis can now distinguish "orphaned worktree (no git root)" from "policy violation" blocks and automatically identifies double-block patterns.

### REFACTOR: PR #907 (2026-06-17)
Background: refactor(#898): rename CI/MOP/SC skill step labels to prefixed format
Changes: Step labels in `/clarify-intent` (CI-N), `/make-outline-plan` (MOP-N), and `/session-close` (SC-N) now use the prefixed format established by PR #779 for other workflow skills. Cross-references across the repo updated accordingly.

### FEATURE: PR #934 (2026-06-17)
Background: fix(#911): remove WORKFLOW_CONFIRM_PR_CREATED sentinel
Changes: Removed `WORKFLOW_CONFIRM_PR_CREATED`: the Claude Code permission dialog no longer shows a raw `echo` sentinel after `gh pr create`. The PR URL is still shown by the `pr-created-open.js` hook (system message); the merge confirmation gate in `/worktree-end` is unchanged.

### FEATURE: PR #935 (2026-06-18)
Background: feat(#920): auto-detect companion issues for co-session fix
Changes: `workflow-init` and `clarify-intent` now automatically surface companion open issues sharing keywords with the primary, with per-candidate confirmation (`AskUserQuestion`). New `CONFIRM_COMPANION_ISSUES` flag (default: `on`) controls the confirmation step; set to `off` to auto-append top candidates silently. Path C sessions and non-GitHub remotes are unaffected.

### FEATURE: PR #938 (2026-06-18)
Background: feat(#925): .env.example comment guideline — rule extension + static checker + full rewrite
Changes: category:FEATURE subject:"#925 — .env.example comment style machine-enforced" changes:"New `review-env-example` checker runs in WF-CODE-6 alongside `review-code-size` and `review-skill-size`. HARD violations (variable-name headings, issue refs, internal implementation names, redundant `Example:` lines, blocks > 5 lines) block the workflow (exit 1); WARN findings are advisory. All 23 existing `.env.example` entries rewritten to comply. Install via `dotfileslink.sh` / `dotfileslink.ps1`."

### FEATURE: PR #936 (2026-06-18)
Background: fix(#913,#905): ensureLayer2Scheduled dual-ID guard + writeLayer2State terminal l2_armed_at null-clear
Changes: Fixed supervisor Layer 2 false-positive reviews after session close: `ensureLayer2Scheduled` now checks both the CC session UUID and the workflow session ID when testing for the final-report anchor, preventing spurious next-session C2 triggers (#913). Fixed stale `l2_armed_at` on terminal phase transitions (`done`/`frozen`) in `writeLayer2State`, eliminating a second source of false-positive C2 blocks (#905).

### FEATURE: PR #945 (2026-06-18)
Background: feat(#928): L2 supervisor report — standardized display format
Changes: L2 supervisor block messages now show structured multi-line output: aggregated `Categories:` line across all findings, per-finding detail list, `Recommended action:` pointer, and explicit session IDs. The branch (3) resume message now leads with human-readable `Clear:` / `To resume` instructions and an explicit `File:` path to the state file, replacing the previous single-line node one-liner.

### FEATURE: PR #946 (2026-06-18)
Background: feat(#944): add test governance, audit-tests.sh, review-code-size fix
Changes: `bin/audit-tests.sh` — new staleness checker: identifies `feature-NNN-*` tests eligible for deletion (CLOSED issue + >3 months since last commit). Run `bin/audit-tests.sh` to get a candidate report; `--offline` skips gh calls; `--format json` for machine-readable output.;`bin/review-code-size` — fixed exclusion bug: was excluding non-existent `tests/_archived/` instead of the actual `tests/_archive/` directory. Both `--all` and diff modes corrected.;`skills/_shared/test-design.md` — new scope classification convention (`scope:issue-specific` / `scope:common`) and size limits (300 WARN / 500 HARD) now documented for test files.

### FEATURE: PR #952 (2026-06-18)
Background: feat(#888,#933): supervisor accuracy (Axis B) — Layer 2 pre-processing + plans-dir exemption
Changes: **EM Supervisor Layer 2**: Added pre-processing step that groups co-blocked findings by the `co_blocked_by` field and clusters findings within a 60-second window into composite items, reducing duplicate root-cause reports. §5 now requires tracing causality chains to the single most-upstream root cause.;**enforce-worktree**: Writing workflow plan files (intent, outline, detail, WORKTREE_NOTES) from the main worktree is now allowed. The hook now permits redirect and tee targets that resolve under `WORKFLOW_PLANS_DIR` via the new `isAllowedWorkflowPlansDirWrite` predicate.

### FEATURE: PR #947 (2026-06-18)
Background: feat(#941): RUN_E2E migrated to .env key via bin/get-config-var
Changes: category:FEATURE subject:"#941 — RUN_E2E .env toggle for claude -p E2E tests" changes:"Set `RUN_E2E=off` (default) in `.env` to skip Anthropic-billable `claude -p` E2E tests across all guarded test scripts. Set `RUN_E2E=on` to enable them. New `.env.example` entry documents the toggle. Both `tests/feature-robust-workflow.sh` E1 block and `tests/feature-644-agent-delegation/phase5-main-transcript-no-delegated-output.sh` now use the standard `bin/get-config-var` reader."

### FEATURE: PR #948 (2026-06-18)
Background: feat(#929): L2 supervisor Codex adversarial review layer
Changes: L2 supervisor now uses a Codex adversarial second-opinion pass on draft findings before finalizing. Findings Codex agrees with pass unconditionally; findings Codex disagrees with are adjudicated by the L2 supervisor (keep or drop). Silently falls back to single-engine mode when Codex is unavailable.

### FEATURE: PR #956 (2026-06-18)
Background: feat(#903,#389,#923): supervisor-guard C3 trigger + load-env realpath fallback + enforce-worktree -C form guard
Changes: Stop hook now detects WORKTREE_OFF / WORKFLOW_OFF off-proposal sentinels immediately when emitted, triggering L2 supervisor review without waiting for the next turn (C3 trigger, #903).;Hooks now load `.env` correctly when the `hooks/` directory is a symlink, fixing WORKTREE_BASE_DIR and other env vars being silently ignored in dotfiles setups (#389).

### FEATURE: PR #960 (2026-06-18)
Background: feat(#912,#914,#903,#372,#545): supervisor L2 API-error handling, C3 WORKTREE_OFF pre-detection, AskUserQuestion gate, WORKTREE_ON warn hook, USER_VERIFIED enforce hook
Changes: doc-append CHANGELOG.md --category BUGFIX --subject "#912 — supervisor L2: fallback recipe in block messages + auto-freeze after 2 retries" --background "Transient API errors in the supervisor subagent could leave the session permanently stalled with no recovery path." --changes "Every L2 block message now includes a freeze recipe: run bin/supervisor-write-layer2 --clear-l2-armed-at --set-l2-phase frozen --session-id <id> to escape an API-error retry loop. The guard now auto-freezes after 2 consecutive invocations (l2_retry_count threshold), so a persistent API error terminates the loop automatically instead of requiring manual state-file surgery.";doc-append CHANGELOG.md --category FEATURE --subject "#903 — C3: WORKTREE_OFF proposals trigger L2 review before approval" --background "Proposed WORKTREE_OFF sentinels were not reviewed before the user was asked to approve them." --changes "supervisor-guard.js now detects a WORKTREE_OFF Bash proposal in the transcript and triggers a Layer 2 review before the user is prompted to approve it.";doc-append CHANGELOG.md --category FEATURE --subject "#914 — AskUserQuestion gate: no L2 block while user is mid-dialog" --background "A Stop-hook L2 block could fire at the same time as an AskUserQuestion dialog, surfacing two simultaneous prompts to the user." --changes "Layer 2 blocking branches are now suppressed when the last assistant turn ends with an AskUserQuestion tool call.";doc-append CHANGELOG.md --category FEATURE --subject "#372 — New Stop hook: advisory warning on unmatched WORKTREE_OFF" --background "A WORKTREE_OFF sentinel without a matching ON could leave the session in off-mode without any notice." --changes "New Stop hook emits an advisory message when a WORKTREE_OFF sentinel appears in the transcript without a subsequent WORKTREE_ON to restore enforcement.";doc-append CHANGELOG.md --category FEATURE --subject "#545 — New Stop hook: enforce AskUserQuestion before WORKFLOW_USER_VERIFIED" --background "The WORKFLOW_USER_VERIFIED sentinel could be emitted without a preceding AskUserQuestion, bypassing the explicit-approval requirement." --changes "New Stop hook blocks the session when WORKFLOW_USER_VERIFIED is emitted without a preceding AskUserQuestion anywhere in the recent multi-turn transcript window."

### FEATURE: PR #964 (2026-06-18)
Background: feat(#953,#882,#922): split robust-workflow tests + fix review-tests staged-token
Changes: Split tests/feature-robust-workflow.sh (1225 → 49 lines dispatcher): removes the pre-existing HARD size violation that caused review-code-size to block every PR that touched this test file;Fix /review-tests stale-token block in linked-worktree sessions: token now computed against the worktree that actually has staged test files, not the main worktree

### FEATURE: PR #972 (2026-06-19)
Background: feat(#942,#697): Claude Code E2E test policy SSOT + dotfileslink transactional safety
Changes: Safer `dotfileslink` install: existing files are now staged to `.bak.tmp` before linking and promoted to `.bak` only after the symlink succeeds, so a failed install no longer loses both the original file and any prior `.bak`. Watchlist `profile-snippet.{sh,ps1}` now warns when any of `CLAUDE.md`, `skills`, `rules`, or `agents` lose their symlink (previously only `CLAUDE.md` was watched). New `RUN_E2E` config flag in `.env` opts into `claude -p` end-to-end tests (off by default; gates exit 77 on opt-out and when `claude` is not on PATH).

### FEATURE: PR #974 (2026-06-19)
Background: fix(#913): supervisor-guard dual-ID readState fallback + stray-} syntax fix
Changes: Fixed: EM Supervisor Layer 2 review now correctly triggers when supervisor state was written under a workflow session ID rather than the CC UUID — previously the Stop hook silently passed, allowing sessions with findings to continue unreviewed.

### FEATURE: PR #976 (2026-06-19)
Background: feat(#971): step-number rule (rules/prompt.md §4) + bin/review-step-numbers + WE/SC renumber
Changes: Decimal-fractional step labels (e.g. WE-2.5, SC-3.5) are now formally prohibited by rules/prompt.md §4; new bin/review-step-numbers lint enforces this at WF-CODE-6 with HARD exit 1.

### FEATURE: PR #978 (2026-06-19)
Background: feat(#811): surface concern summary before cap-menu AskUserQuestion dialog
Changes: Cap-menu dialog now shows a structured concern summary (concern ID, severity, body, resolution status, remaining extensions) immediately before the Land/Adjust/Extend choice, giving users the context they need to decide at round cap.

### BUGFIX: PR #977 (2026-06-19)
Background: fix(#893,#954): get-config-var symlink resolution + --is-off exit code hardening
Changes: `get-config-var --is-off` now correctly reads `.env` when installed as a symlink (e.g. dotfiles setups via `dotfileslink`). `CONFIRM_*` flag reads no longer silently return ON when the script is invoked via `~/.local/bin/`. (#893);`get-config-var --is-off` now exits 2 when the key is unset and no default was supplied (previously treated as ON without diagnostic). Exits 3 for unrecognized values with a stderr warning. Exits 4 on internal failure. Usage error exits 64. These new codes all map to the ON branch of the `&& echo OFF || echo ON` idiom, so existing call sites are unaffected. (#954)

### FEATURE: PR #979 (2026-06-19)
Background: feat(#968): replace companion-issue keyword search with 3-pass explicit-signal detection
Changes: Companion issue suggestions now show why each issue was flagged (xref, identifier overlap, or sibling relationship) instead of a bare title.;`workflow-init` no longer prompts about companion issues; companion detection is now handled exclusively by `clarify-intent`.;`CONFIRM_COMPANION_ISSUES` config removed; each companion candidate now always requires confirmation.

### FEATURE: PR #985 (2026-06-20)
Background: fix(#955,#967,#975,#933): supervisor guard/trigger/state-writer L2 lifecycle fixes
Changes: Fixed: EM Supervisor Stop hook no longer permanently blocks the session after Layer 2 review completes (`l2_phase=frozen` or `done`). Sessions with acknowledged errors can continue. (#955);Fixed: EM Supervisor can now schedule a fresh Layer 2 review after a frozen session resumes work — new findings after a freeze are no longer silently dropped. (#967);Fixed: EM Supervisor no longer triggers a Layer 2 review when WORKFLOW_OFF is pre-authorized with no blocking findings. Notice-only sessions no longer cause spurious reviews. (#975)

### FEATURE: PR #989 (2026-06-20)
Background: fix(#987): detect reparse-point in Write-Launcher before WriteAllText
Changes: Fixed a bug where running `dotfileslink.ps1` after `dotfileslink.sh` under WSL caused `Write-Launcher` to follow symlinks and overwrite `bin/` source files with shim content.
### CONFIG: Eliminate permission dialogs for git fetch/pull in EnterWorktree sessions (2026-06-20)
Background: Git fetch and pull commands issued from linked worktree CWD had no allow rules, causing interactive permission dialogs mid-workflow.
Changes: Added allow rules for `git fetch origin *`, `git fetch --prune origin`, and `git pull --rebase --autostash origin *` (plus `-C *` variants of each).

### FEATURE: PR #993 (2026-06-20)
Background: fix(#239,#240): inline gitignore matcher, remove ignore npm dependency
Changes: worktree-start no longer fails with `Cannot find module 'ignore'` on fresh clones. The npm dependency `ignore@5.3.2` has been removed and replaced with an inline matcher; `package.json` and `package-lock.json` have been deleted.

### FEATURE: PR #995 (2026-06-20)
Background: fix(#451,#469,#543): session-id error hints, cleanupZombies marker files, wip-state --session-id
Changes: Fixed: WIP conflict detection no longer misidentifies the current session when multiple Claude Code sessions run concurrently. `wip-state.sh` now accepts an injected session ID, eliminating the racy JSONL mtime scan. (#543);Fixed: Orphaned `.workflow-off` and `.worktree-off` marker files from past sessions are now cleaned up after 7 days. (#469);Fixed: WIP rc=2 error hints in `clarify-intent` and `workflow-init` now name both `$CLAUDE_ENV_FILE` and `$CLAUDE_SESSION_ID` as triage targets. (#451)

### FEATURE: PR #999 (2026-06-20)
Background: refactor(#970,#860): split tests/fix-workflow-gate-unix-path.sh per Pattern A
Changes: Refactored 743-line test file `tests/fix-workflow-gate-unix-path.sh` into a 5-file source-dispatch layout for maintainability (#970)

### FEATURE: PR #1002 (2026-06-20)
Background: feat(#980,#677): add bin/confirm-off + bin/confirm-off.ps1 helpers and fix load-env.js empty-string shadowing
Changes: confirm-off helper (bash + PowerShell) added: SKILL.md confirm gates now use `bash "$AGENTS_CONFIG_DIR/bin/confirm-off" KEY default` — eliminates exit-code ambiguity and PATH lookup failures (WSL bash on Windows);`.env` flag vocabulary narrowed: only `off` turns off a confirm gate; `0`, `false`, `no`, `disabled` are no longer accepted and now fail-safe to ON

### FEATURE: PR #1004 (2026-06-20)
Background: feat(#990): add scan-offensive CLI + /scan-offensive skill + forward filter
Changes: Added `scan-outbound.js` forward filter for offensive content in `gh issue/pr` writes; populate `.offensive-content-blocklist` and/or set `ANTHROPIC_API_KEY` to activate (all repos, public and private);Added `/scan-offensive` skill for retroactive scanning and redacting offensive content in any GitHub repo's issues and comments

### FEATURE: PR #1006 (2026-06-21)
Background: feat(#866): remove drafts/ subdirectory from ~/.workflow-plans/
Changes: `~/.workflow-plans/` no longer has a `drafts/` subdirectory — all planner intermediate files now live at the root alongside final artifacts, distinguished by filename suffix.

### FEATURE: PR #1013 (2026-06-21)
Background: fix(#350,#986): remove PREMISE sentinel infrastructure, rewrite MOP-0c to abort-only
Changes: When `make-outline-plan` detects a premise contradiction in survey artifacts, it now always aborts with a message directing you to fix `intent.md` and re-run `/clarify-intent`. The previous "acknowledge and proceed" option has been removed — it was redundant because the downstream EM Supervisor would catch any intent drift anyway. (#986);Re-running `/make-outline-plan` after acknowledging a contradiction in `/clarify-intent` no longer prompts about the same contradiction a second time. The abort-only gate eliminates the double-confirmation UX issue. (#350)

### FEATURE: PR #1018 (2026-06-21)
Background: fix(#992): replace bare python3/python -c with uv run python -c; add review-bare-python lint guard
Changes: Fixed: Microsoft Store popup no longer appears during `/run-tests` on Windows; three `.sh` scripts replaced bare `python3`/`python -c` with `uv run python -c`.;Added: `review-bare-python` lint guard detects bare `python3`/`python -c` in `.sh` files and runs automatically in WF-CODE-6.

### FEATURE: PR #1019 (2026-06-21)
Background: feat(#966): add PREFIX-N. step labels to remaining 25 SKILL.md files; fix survey-history SH-3; remove lint exclusion
Changes: All 32 SKILL.md files now carry globally unique step labels (`CP-1.`, `SH-3.`, `WT-7.`, etc.) — cross-references like "survey-history step 3" are unambiguous. The `survey-history` `Step 2.5` decimal violation and its lint exclusion are resolved.

### FEATURE: PR #1022 (2026-06-21)
Background: fix(#962): move cap gate post-verdict in codex review loop
Changes: After a planner revises a draft in response to reviewer concerns, the revised draft now always reaches the reviewer for a confirmation check — previously it was silently skipped when the review count hit the cap before the confirmation round could fire.
### REFACTOR: split bin/github-issues/wip-state.sh into wip-state/ sibling folder (2026-06-21)
Background: bin/github-issues/wip-state.sh reached 604 lines — a HARD limit violation per rules/coding/file-split.md. Applied Pattern A split; no user-visible behavior change.
Changes: bin/github-issues/wip-state.sh entrypoint shrunk from 604 to 213 lines; verb logic extracted to 5 sourced subfiles under bin/github-issues/wip-state/. CLI interface unchanged.

### FEATURE: gate-plan-skip-sentinel: add CONFIRM_TESTS=off gate (#1014) (2026-06-21)
Background: CONFIRM_TESTS=off gate was missing for the WORKFLOW_WRITE_TESTS_NOT_NEEDED sentinel.
Changes: `CONFIRM_TESTS=off` now also suppresses the `WORKFLOW_WRITE_TESTS_NOT_NEEDED` sentinel permission dialog, in addition to the existing test-file content review gate.

### FEATURE: PR #1031 (2026-06-21)
Background: feat(#1027,#961,#997): surface L2 supervisor findings at session close; fix l2_phase stale-pending and late-finding arm
Changes: Layer 2 supervisor findings (severity >= warning) are now surfaced at session close after the Final Report — non-blocking L2 completions no longer go silent; a Stop hook provides autonomous fallback display when session-close does not run normally (#1027/#961/#997).

### FEATURE: PR #1033 (2026-06-21)
Background: feat(#990/#1010/#1011): add /scan-offensive skill — JSONL manifest, inline CC evaluation, prompt injection protection
Changes: `/scan-offensive` skill now scans **all** issues and comments retroactively and emits a JSONL manifest; Claude evaluates each item inline with XML-entity-escaped content envelopes guarding against prompt injection — no external API key required on the skill path.;`bin/scan-offensive --skill-mode` new flag: produces JSONL manifest (preamble + per-item records with keyword verdicts, SHA-256 content hashes, and injection-safe envelopes) for all items regardless of keyword hits.;`scan-repo.sh` range filters: `--since`/`--until` (date), `--from-issue`/`--to-issue` (issue number), `--limit N` — batch large repos without scanning everything in one pass.;`scan-repo.sh --apply`: redact confirmed items from a previous manifest; stale-check (SHA-256) exits 5 if the body changed; canary mode redacts the first item and pauses for confirmation.

### FEATURE: PR #1032 (2026-06-21)
Background: fix(#1023,#961,#997,#1020): resolve supervisor L2 deadlock and session-ID routing
Changes: SC-5 (`/session-close`) no longer hangs indefinitely when L2 review was triggered by a non-orchestrator agent: elapsed-time fallback fires after 10 minutes and allows the Final Report to proceed;Session-close anomalous state (L2 armed marker missing) now surfaces as an error finding in the audit trail instead of silently passing through;Supervisor L2 agent (`agents/supervisor.md`) now correctly resolves its own state file when multiple session IDs are in play, and verifies the finalize write actually completed

### FEATURE: PR #1034 (2026-06-21)
Background: fix(#969,#965): dotfileslink hardening — junction rollback, dangling-link detection, test sandbox
Changes: **dotfileslink hardening (#969, #965)**: On Windows, `install/win/dotfileslink.ps1` now correctly restores Junction-type destinations on rollback (previously always restored as SymbolicLink, leaving a dangling stub). Profile startup health checks (`profile-snippet.ps1`, `profile-snippet.sh`) now detect dangling symlinks (target path gone) in addition to missing or regular-file occupants, triggering automatic repair. On Linux/Git-Bash, `_link_one` in `install/linux/dotfileslink.sh` now reports and returns an error when `rm -f` or `mv` fails instead of silently continuing.

### FEATURE: PR #1038 (2026-06-21)
Background: fix/fix-1028-1029
Changes: Fixed regression where workflow-init and clarify-intent still asked "Which is the primary issue?" in multi-issue sessions after the primary-abolition change in a prior release

### BUGFIX: PR #1042 (2026-06-22)
Background: fix(#983,#878): plans-dir env-var expansion in redirect/tee; narrow null-repoRoot guard
Changes: `/issue-close-finalize` worker state file writes (e.g. `cat > "$state_path.tmp"`) from the main worktree are no longer blocked by `enforce-worktree`; sanctioned `rm ~/.workflow-plans/*.tmp` from a non-repo CWD is also no longer blocked.

### FEATURE: PR #1041 (2026-06-22)
Background: feat(#720,#957,#1021): EM Supervisor Layer 3 strategic review; enforce-worktree plans-dir allowlist; supervisor-report dual-store mirror
Changes: Layer 3 (Opus-class strategic review) added to the EM Supervisor. The Stop hook arms an L3 review at each workflow stage boundary (CONFIRM_INTENT/OUTLINE/DETAIL) and when cumulative error severity is reached; the L3 agent examines cross-stage coherence and escalation patterns and produces a CONTINUE/WARN/BLOCK verdict. (#720);Fixed: `node bin/supervisor-report`, `node bin/supervisor-write-layer2`, and `node bin/supervisor-write-layer3` commands issued from a linked worktree were blocked by the enforce-worktree hook. These scripts now appear in the plans-dir allowlist. (#957);Fixed: supervisor findings written by non-orchestrator agents may not reach downstream readers that use a different session-ID form (CC UUID vs wsid). `supervisor-report` now mirrors findings to both stores when the session ID is auto-resolved. (#1021)

### FEATURE: PR #1050 (2026-06-23)
Background: fix(#927,#481,#988,#1047): delete INLINE_SKILL_RE; add /issue-close-migrated skill; fix --reason not_planned; verify hook/runtime claims in codex
Changes: **Hook:** `gh issue close` inline bypass form (`ISSUE_CLOSE_SKILL=1 gh issue close N --reason completed` as a literal command prefix) removed — was fragile and blocked all natural subagent-generated command shapes. The env-export form (`export ISSUE_CLOSE_SKILL=1`) is now the sole bypass for direct Bash-tool calls.;**New skill:** `/issue-close-migrated` — close issues as `status:migrated` or `status:cancelled` with `--reason not_planned`. Usage: `/issue-close-migrated N --type migrated --into M` or `/issue-close-migrated N --type cancelled`.;**Hook message:** `enforce-issue-close.js` now routes `--reason not_planned` commands to `/issue-close-migrated` and default closes to `/issue-close-finalize`.;**Codex review:** Hook-scope concerns in codex review (touching `enforce-issue-close`, `PreToolUse`, `ISSUE_CLOSE_SKILL`, `command-head.js`) are now mechanically auto-rejected unless they carry a `[verified: <files>]` annotation — the reviewer must read the hook source via `read_file` before the concern is accepted into the ledger.

### FEATURE: PR #1055 (2026-06-23)
Background: fix(#1049): state-first guard in wip-state clear prevents Status=Done on open issues
Changes: Fixed: `wip-state clear` no longer accidentally closes open issues via Projects v2 Status=Done when removing a stale WIP lock.

### FEATURE: PR #1054 (2026-06-23)
Background: fix(#939,#1043,#1044,#1051,#1052,#883): L3 supervisor: wire Phase B arbitrate, fix T5 arm, SC-5b stale-pending, wsid routing, session-ID stanza, test rename
Changes: L3 review WARN and BLOCK verdicts now surface at the next Stop event — previously WARN was dropped and BLOCK was unreachable when L2 phase was done/frozen (#1043, #1044);`/session-close` now repairs stale L3 pending state using the same elapsed-time heuristic as the L2 SC-5 repair (#1051);`bin/supervisor-write-layer3` now mirrors writes to both wsid and CC UUID stores when both are available, matching `bin/supervisor-report` behavior (#1052);L3 arm block reason now shows Session ID, Workflow session ID, and Effective state session ID separately for easier cross-store debugging (#883)
