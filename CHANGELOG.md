## Archived
- [2026](changelog/2026.md) — 113 entries

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

### FEATURE: PR #1056 (2026-06-23)

Background: refactor(#1053): replace prose WF-CODE-N workflow with oracle-driven state machine

Changes: REFACTOR: Workflow step sequencing is now oracle-driven — after each skill the model queries `bin/workflow/next-step` for the next step, replacing the previous prose STEP_HINT table injected via PostToolUse hooks. The CLAUDE.md Workflow section is now dispatch-only (oracle pointer + ## Notes).

### FEATURE: PR #1065 (2026-06-23)

Background: refactor(#1045): replace enforce-worktree allowlist with universal session-scope target-aware allow

Changes: enforce-worktree (`ENFORCE_WORKTREE=on`): Bash writes from the main worktree are now allowed whenever every parseable write target resolves outside the session scope — covering plans-dir paths, `/tmp`, and other out-of-repo destinations without explicit per-target allowlists. Set `ENFORCE_WORKTREE_EXTRA_REPOS` (semicolon-separated repo paths) to extend the session scope when working across sibling repositories.

### FEATURE: PR #1074 (2026-06-24)

Background: refactor(#1071): skill/agent fork+worker audit — context:fork sweep cluster, 4 new workers, user-invocable audit

Changes: **Skill picker:** `/issue-close-migrated`, `survey-code`, `survey-history`, and `issue-reconcile` no longer appear as direct-invocation candidates in the skill picker — they are internal-only skills invoked by other skills.

### FEATURE: PR #1075 (2026-06-24)

Background: fix(#1073,#319): doc-rotate archives CHANGELOG.md to changelog/; doc-append launcher sets MSYS_NO_PATHCONV=1

Changes: Fixed: `doc-append CHANGELOG.md` now archives to `changelog/<year>.md` instead of `history/<year>.md`; `## Archived` links and headers are correct; re-rotation no longer duplicates the `## Archived` block. (#1073);Fixed: `doc-append` bash wrapper now sets `MSYS_NO_PATHCONV=1`, preventing Git Bash from mangling Unix-style path arguments (e.g. `/worktree-start`) to Windows paths. (#319)

### FEATURE: PR #1084 (2026-06-25)

Background: feat(#1077): add WORKFLOW_ISSUE_CLOSE_VERIFIED session-scoped bypass for gh issue close

Changes: New `<<WORKFLOW_ISSUE_CLOSE_VERIFIED: reason>>` / `<<WORKFLOW_ISSUE_CLOSE_VERIFIED_END: reason>>` sentinel pair: lets you approve a window of planned `gh issue close` operations without triggering supervisor alerts or using the broader WORKFLOW_OFF bypass.

### FEATURE: PR #1088 (2026-06-25)

Background: fix(#1080): extend workflow-gate plans-path allowlist to Edit and MultiEdit

Changes: Workflow gate now allows Edit and MultiEdit tools to target `~/.workflow-plans/` files during the `clarify_intent` pending phase, so skills can patch existing plan files (intent.md, outline.md) without being blocked.

### FEATURE: PR #1086 (2026-06-25)

Background: feat(#299): auto-set VS Code session title from workflow state

Changes: VS Code session titles are now set automatically: `#N issue-title` at session open, `⏳ #N issue-title` while waiting for user input, `#N issue-title PR #N` appended after commit-push, and `✓ #N issue-title PR #N` prepended when the session closes cleanly.

### FEATURE: PR #1089 (2026-06-25)

Background: fix(#917,#1078,#1079): CONV_LANG/PLAN_LANG compliance — fallback headers, orchestrator localization, UUID artifact fix

Changes: Planning confirmation dialogs (make-outline-plan, make-detail-plan) now respond in the language configured via `CONV_LANG`;Fixed `PLAN_LANG` enforcement: plan artifact language checks were silently skipped for all current sessions due to a session ID format mismatch in `hooks/check-plan-lang.js`

### FEATURE: PR #1092 (2026-06-25)

Background: feat(#1067): EM Supervisor L2/L3 → alert/audit two-mode merge

Changes: EM Supervisor: L2/L3 unified into alert/audit two-mode design — alert mode (Sonnet, narrow) and audit mode (Opus, broad) replace the old layer2/layer3 naming. C3 trigger now detects both WORKTREE_OFF and WORKFLOW_OFF proposals. Arming threshold raised to severity≥warning (notice-only sessions no longer arm the supervisor). Final Report gains Supervisor Alert and Supervisor Audit summary sections.

### BUGFIX: Concurrent sessions could resolve the wrong session id (#1082) (2026-06-25)

Background: Running multiple Claude Code sessions at the same time could corrupt workflow state because a session sometimes resolved a different session's id instead of its own.

Changes: Each session now reliably resolves its own session id, so concurrent sessions no longer collide on workflow state.

### FEATURE: PR #1090 (2026-06-25)
Background: feat(#721): add WF-PLAN workflow type for meta-label issues
Changes: `meta` label issues now use a shorter WF-META flow — oracle auto-skips 8 non-applicable steps (tests, branch, security review, docs, user verification, cleanup) so workflow-init through session-close completes with only the planning steps. When a new issue looks like it may require multi-session decomposition, `clarify-intent` now probes for decomposition signals and proposes WF-META to the user.
