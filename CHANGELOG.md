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

### FEATURE: PR #1098 (2026-06-25)
Background: fix(#1067): add migrateLegacyState() to handle pre-#1092 state files
Changes: Fixed: `supervisor-report` no longer crashes with "validate failed: alert must be an object; audit must be an object" on sessions that had state files written before PR #1092.

### FEATURE: PR #1106 (2026-06-26)
Background: fix(#721): add "detail" to WF_META_AUTO_SKIP — WF-META sessions no longer invoke make-detail-plan
Changes: WF-META sessions no longer invoke `make-detail-plan`: the oracle now auto-skips `detail` (along with 8 other non-applicable steps) after `outline` completes.

### FEATURE: PR #1111 (2026-06-26)
Background: fix(#1094,#1064): evidence-based step completion for clarify_intent and docs — gate and oracle auto-repair
Changes: `workflow-gate` and oracle now auto-repair stale `clarify_intent=pending` state when `<sessionId>-intent.md` already exists — no more `WORKFLOW_OFF` workaround needed after a session restore or state reset.;Oracle auto-completes the `docs` step when staged doc changes or `WORKTREE_NOTES.md` bullets are present, eliminating false "re-run `/update-docs`" instructions.

### FEATURE: PR #1110 (2026-06-26)
Background: feat(#1097): add block-memory-direct.js PreToolUse hook to intercept agents-repo memory writes
Changes: Memory writes to the agents-repo behavior notes directory are now intercepted; CC presents a choice to create a GitHub issue (recommended), allow the write (one-shot per session), or cancel.

### FEATURE: PR #1118 (2026-06-26)
Background: fix(#1103): block subagent sentinel pollution via PreToolUse hook + workflow-mark backstop
Changes: Fixed: subagents running in parallel with the main conversation can no longer accidentally reset or advance workflow steps — only the orchestrator (main conversation) can emit workflow sentinels.

### FEATURE: PR #1116 (2026-06-26)
Background: fix(#1105,#703): per-segment quote-aware test-command detection + harness path
Changes: Fixed a workflow bug where commands using `git -C <path>`, or compound/diagnostic commands that merely reference a `tests/` path (e.g. `node build.js && wc -l tests/x`), could prematurely mark the test step complete and trigger false "inconsistent state" workflow aborts.

### FEATURE: PR #1125 (2026-06-26)
Background: fix(#1114): surface per-finding detail in Final Report Supervisor Findings section (#1125)
Changes: The session-close Final Report's `### Supervisor Findings` section now shows per-finding detail (categories, severity, detail, reporter) instead of only an aggregate count — findings remain visible even when SC-7 is skipped because findings were already surfaced earlier in the session

### FEATURE: PR #1126 (2026-06-26)
Background: fix(#1095,#1024,#982,#286,#234): enforce-worktree false-positive fixes + migration cleanup
Changes: enforce-worktree guard no longer false-blocks git merge-base, git stash drop/clear, or rm $VAR (scratchpad cleanup) from the main worktree (#1095, #1024);enforce-worktree: git worktree add ... && cd <path> chains now pass through from main worktree; git -C <main-path> worktree remove/prune from linked worktrees also fixed (#982, #838);enforce-worktree: subagents launched from a linked worktree no longer mistakenly blocked — tool CWD is now used for repo-root detection (#286)

### FEATURE: PR #1121 (2026-06-26)
Background: fix(#299): write ⏳ sentinel for untitled sessions; let issue # override sentinel
Changes: VS Code session title now shows ⏳ reliably for all sessions including fresh ones with no workflow issue; issue number appears in the tab after /workflow-init runs even if a prompt was submitted before the intent was created

### FEATURE: PR #1130 (2026-06-26)
Background: fix(#1107,#1085,#1083): write_tests evidence auto-repair, abort hint cleanup, RESET_FROM error
Changes: Workflow oracle now auto-completes the `write_tests` step when staged test files are present, eliminating the need for manual `WORKFLOW_RESET_FROM_write_tests` workarounds when tests are written before the step is formally advanced.;Oracle abort messages no longer expose the `WORKFLOW_RESET_FROM_` recipe; recovery guidance now points to `/workflow-init` exclusively.;Unknown step names in `WORKFLOW_RESET_FROM_<step>` sentinels now produce an actionable error listing all valid step names instead of a silent "ignored" message.
### FEATURE: Early WIP claim, companion WIP/parent filter, primary candidate filter (#1117,#1081,#1005) (2026-06-26)
Background: Three related issues: #1117 (wip-set-resume NEEDS_CLARIFY branch did not claim WIP before exit, leaving session unclaimed on resume), #1081 (companion issue filter included parent and WIP-claimed-by-other candidates), #1005 (workflow-init had no filter for multiple primary candidates).
Changes: wip-set-resume now claims WIP before exiting in the NEEDS_CLARIFY branch; companion candidate filter excludes parent-of-primary and WIP-claimed-by-other issues; new primary candidate filter script for workflow-init; clarify-intent claims WIP on companion accept.

### BUGFIX: PR #1136 (2026-06-27)
Background: fix(#1123): exclude extensionHost from isVsCode() CLAUDE_CODE_ENTRYPOINT clause
Changes: Fixed: VS Code extension (extensionHost) users no longer receive unexpected plan-file auto-open popups when plans are written

### FEATURE: PR #1143 (2026-06-27)
Background: fix(#1138,#1112): cross-repo bypass and cleanup exemption in workflow-gate
Changes: `workflow-gate.js` no longer blocks `git -C <foreign-repo> commit` when the target repo is not the agents session repo (cross-repo bypass for #1138).;`workflow-gate.js` no longer blocks on a pending `cleanup` step during worktree-based sessions; cleanup is deferred to `/worktree-end` (fix for #1112).

### FEATURE: PR #1140 (2026-06-27)
Background: fix(#927): replace ISSUE_CLOSE_SKILL=1 inline form with close-completed.sh subprocess in ICF-H
Changes: `/issue-close-finalize` now reliably closes issues: the ICF-H step was silently blocked by `enforce-issue-close.js` because `ISSUE_CLOSE_SKILL=1` set in a Bash subprocess cannot reach the hook's process environment. Closes no longer fail silently when run via the finalize skill.

### FEATURE: PR #1144 (2026-06-27)
Background: fix(#1137): prohibit caller re-summary after deep-research DR-3 output
Changes: Fix /deep-research double output: calling orchestrators no longer re-summarize findings already presented by the skill (DR-3 caller-prohibition directive).

### FEATURE: PR #1157 (2026-06-27)
Background: fix(#1115,#982,#923,#838,#959): enforce-worktree false-block fixes — fd-dup redirect chaining misread, -C flag validation, worker script paths
Changes: POSIX I/O redirects (`2>&1`, `N>&1`, `N>&-`) in sanctioned git commands no longer false-block `enforce-worktree.js` (#1115, #982).;`git -C <path> worktree remove/prune/add` now passes `enforce-worktree.js` from both main-worktree and linked-worktree CWDs (#923, #838).;Sanctioned worker scripts (`issue-close-stage-worker`, `commit-push-worker`, etc.) launched from the main worktree with linked-worktree path arguments no longer false-block (#959).

### FEATURE: PR #1159 (2026-06-27)
Background: fix(#1120): return null from resolveWorkflowSessionId when no ccBucket=0 owner identified among same-day candidates
Changes: Fixed: supervisor C2 scheduled review no longer reports findings from unrelated parallel sessions when the active session cannot be identified from context files.

### FEATURE: PR #1158 (2026-06-27)
Background: feat(#485): advisory plan-skip hints (SKIP_HINT) at outline/detail for trivial changes
Changes: The workflow oracle (`next-step`) now suggests skipping the outline/detail planning stages for trivial changes (advisory only; you still confirm the skip).

### FEATURE: PR #1167 (2026-06-27)
Background: fix(#299): clarify-intent Path B set-issue + remove dead ⏳ code
Changes: Session title now shows issue number and title (`#N <title>`) in sessions that start via `clarify-intent` (Path B); previously only `workflow-init` sessions updated the title.;Removed defunct ⏳ waiting-lifecycle hook files left on disk after PR #1142; `⏳` can no longer reappear from these code paths.

### FEATURE: PR #1171 (2026-06-27)
Background: fix(supervisor-guard): symmetric C3 done/frozen guard + scope detectOffProposal to Bash tool_use
Changes: Fixed supervisor adjudication being dropped in rounds 2+ when a bypass-proposal review was already completed (alert_phase=done) (#1163); fixed self-reinforcing C3 false-positive loop triggered when supervisor prose mentioned bypass-keyword strings (#1162).

### FEATURE: PR #1173 (2026-06-27)
Background: feat(#1155): bulk-sub-of verdict for /issue-create + --skip-survey flag + WF-META PM4 mandate
Changes: `/issue-create` now supports a `bulk-sub-of` verdict: pass a TSV manifest to create and attach multiple sub-issues under a meta parent in one pass, with partial-failure recovery and per-child URL output.;New `--skip-survey` flag bypasses the per-issue dedupe survey for callers that have already pre-screened candidates (e.g. WF-META bulk creation workflows).

### FEATURE: PR #1178 (2026-06-27)
Background: fix(#1108): unify artifact_dir to PLANS_DIR across issue-create, issue-reconcile, worktree-start, session-close
Changes: Worker artifacts from `/issue-create`, `/issue-reconcile`, `/worktree-start`, and `/session-close` are now written under `PLANS_DIR` (same directory as session plan files) and are therefore automatically swept by `/sweep-plans`; previously they landed in `artifacts/` and were never auto-cleaned

### FEATURE: PR #1179 (2026-06-27)
Background: fix(#1109,#983,#1025,#1040): allow heredoc and env-var-expanded writes to WORKFLOW_PLANS_DIR
Changes: fix: enforce-worktree no longer false-blocks writes to `~/.workflow-plans/` from the main worktree when the command uses heredoc bodies with shell sequencing (`cat <<'EOF' > "$WORKFLOW_PLANS_DIR/file"`), variable-expanded redirect targets (`echo x > "$STATE_PATH"`), or `mv` with plans-dir variables (`mv "$PLANS_DIR/foo.tmp" "$PLANS_DIR/foo"`).

### FEATURE: PR #1183 (2026-06-27)
Background: fix(#1176): restore VS Code auto-open + add clickable vscode:// breadcrumb links in plan confirmation flow
Changes: Fixed: plan confirmation flow (intent/outline/detail) now auto-opens in VS Code and shows a clickable file link in extension chat — regression from PR #1136 extensionHost guard; use SHOW_PLAN_LINK_NO_AUTO_OPEN=1 to opt out

### FEATURE: PR #1182 (2026-06-28)
Background: fix(#1099): guard resolveSessionId P7 against cross-repo CWD
Changes: Fixed: in multi-repo setups running concurrent sessions, the workflow's last-resort session-id fallback could occasionally attribute state to another session when invoked from a different repository's directory. It now skips foreign repositories, keeping each session's workflow state correctly attributed.

### FEATURE: PR #1189 (2026-06-28)
Background: fix(#1181): guard WI-8 against WF-META when meta issue has open sub-issues (#1189)
Changes: `/workflow-init` given a meta issue that already has open sub-issues now presents those sub-issues as candidates to work on, instead of silently entering WF-META and risking duplicate sub-issue creation.

### FEATURE: PR #1194 (2026-06-28)
Background: feat(#1100,#1101): cross-repo wire format + parse-closes-issues.js extension + close flow --repo support
Changes: Cross-repo issue references now supported in session intent files: use `- repo#N: title` or `- owner/repo#N: title` in the `## Issues` section alongside the existing `- #N: title` form;Issue close flow (`/issue-close-stage`, `/issue-close-finalize`) correctly handles issues from foreign repositories — no more 404 errors when closing cross-repo sessions

### FEATURE: PR #1193 (2026-06-28)
Background: fix(#1192): fail-close stop-final-report-guard when worktree done; SC-6 CONV_LANG
Changes: BUGFIX: Stop hook now blocks session close when worktree cleanup is done but Final Report is absent — previously the hook passed silently; it now prompts `/session-close` with a language-aware message (follows `CONV_LANG`)

### FEATURE: PR #1186 (2026-06-28)
Background: feat(#1147 T0): BUGFIX session gate — fail-before-fix enforcement
Changes: BUGFIX sessions (fix/* branches) now enforce fail-before-fix: write_tests and review_tests cannot be skipped, WRITE_TESTS_NOT_NEEDED is rejected, and doc-append entries to history.md require --test-gap

### FEATURE: PR #1211 (2026-06-28)
Background: fix(#1205): session-sync reset mtime wrong when JSONL tail is metadata-only
Changes: `session-sync reset` now restores session order correctly after VS Code restart — was reading wrong timestamp (session-start instead of last real exchange) when metadata-only lines (ai-title, pr-link) followed the final JSONL entry;New `cc-session-mtime` / `cc-session-mtime.ps1` commands repair session list ordering without a full git sync (`--dry-run` for preview)

### FEATURE: PR #1213 (2026-06-29)
Background: fix(#1133): oracle --mark CLI + outline/detail evidence auto-repair + scoped hint
Changes: When context compaction leaves outline or detail planning steps in an inconsistent state, the workflow oracle now auto-repairs from on-disk artifacts and continues — no manual recovery needed. When auto-repair is not possible, the oracle gives an actionable `node bin/workflow/next-step --mark <step> complete` command instead of a generic error.

### BUGFIX: Workflow continues automatically between steps; fewer spurious confirmation prompts (2026-06-29)
Background: Stop-at-every-stage and premature worktree-side verification prompts.
Changes: After a workflow skill finishes, Claude now continues to the next step automatically instead of pausing to ask 'the next step is /X — proceed?' at every stage boundary; confirmation prompts are reserved for real decision points. The documentation-update step no longer asks for final verification on the worktree side before a PR exists.

### FEATURE: PR #1220 (2026-06-29)
Background: feat(#1149,#1001,#1208): T1 test quality — table-driven mandatory, mutation probe, false-green detection
Changes: New test quality enforcement for parser/regex changes: table-driven tests are now required when editing parser, regex, or allowlist files (`bin/check-table-driven.sh`); same-literal false-green assertions are detected and blocked (`bin/check-false-green.sh`); a lightweight mutation probe (`bin/mutation-probe.sh`) verifies that regex constants are actually exercised by tests (mutation score ≥80% threshold)

### FEATURE: PR #1227 (2026-06-30)
Background: fix(#1225): profile-snippet.sh fetch guards + idempotency
Changes: Session sync fetch at iTerm startup no longer suspends the zsh job or corrupts the prompt/PATH when SSH passphrase is not cached. `profile-snippet.sh` is now truly idempotent when sourced from both `.profile_common` and `.zshrc`.

### FEATURE: PR #1227 (2026-06-30)
Background: fix(#1225): profile-snippet.sh fetch guards + idempotency
Changes: Session sync fetch at iTerm startup no longer suspends the zsh job or corrupts the prompt/PATH when SSH passphrase is not cached. `profile-snippet.sh` is now truly idempotent when sourced from both `.profile_common` and `.zshrc`.

### FEATURE: PR #1221 (2026-06-30)
Background: feat(#1102,#1104): multi-repo worktree sessions — sibling intent schema + worktree-end fan-out
Changes: Multi-repo worktree sessions: `clarify-intent` now detects cross-repo issue refs and prompts for sibling worktree paths; `worktree-end` writes history/changelog entries to each sibling repo automatically

### FEATURE: PR #1238 (2026-07-02)
Background: feat(#1226): OS-conditional .env blocks (#@if windows/posix) across all 3 loaders
Changes: `.env` now supports OS-conditional blocks. Wrap OS-specific lines in `#@if windows` / `#@if posix` / `#@endif` markers: Windows keeps the `#@if windows` blocks, macOS/Linux keeps the `#@if posix` blocks, and the marker lines are stripped when the file is read. This lets one shared `.env` keep a single source of truth for cross-platform settings (API keys, IDs) while path-format settings (e.g. `WORKTREE_BASE_DIR`) carry per-OS values — fixing Windows drive-letter/backslash paths being silently dropped on macOS.;A flat `.env` with no markers keeps working exactly as before — no migration is required unless you want per-OS path values.;Migration (only if you want per-OS path values in a shared `.env`): manually wrap your OS-specific path settings in `#@if windows` / `#@if posix` / `#@endif` blocks, using the updated `.env.example` as the template. Your real `.env` is never auto-edited (it holds secrets and is git-ignored), so this step is yours to apply.

### FEATURE: PR #1239 (2026-07-02)
Background: fix(#1234,#1232): /migrate-repo self-repo identity guard + canary-1 label sync
Changes: /migrate-repo now confirms the migration target repository explicitly and refuses to migrate the agents repo into itself unless intentionally acknowledged, preventing accidental migration when a repo path is mentioned only as a reference.;Fixed /migrate-repo failing with "label not found" on a fresh repository: the first history migration step now syncs labels before creating any issue.

### FEATURE: PR #1260 (2026-07-03)
Background: feat(#1236,#457,#1235): target-visibility leak guard + Universality First + exclude-repos
Changes: Content pushed to a public repository (issue/PR titles and bodies) is now scanned for private-repository name leaks based on the destination repository's visibility, not just your current directory — reducing the risk of a private repo name slipping into a public issue or pull request.;New `ENFORCE_WORKTREE_EXCLUDE_REPOS` setting: list specific repository root paths (semicolon-separated absolute paths) to exempt them from worktree enforcement so you can edit and commit them directly from any branch. It does not disable enforcement globally — only the listed paths are exempt.

### FEATURE: PR #1266 (2026-07-03)
Background: fix(#1231,#1204): migrate-repo symlink docs/ cross-repo commit + find-pr-by-marker --repo fallback
Changes: `/migrate-repo` Step 6 now works correctly when `docs/` is a symlink to a shared docs repo (e.g. my-specs-repo). Previously the step aborted with "pathspec beyond a symbolic link"; it now commits docs artifacts to the symlink-target repo in a separate commit and push.;Issue-close finalize: the fallback PR lookup no longer risks matching a PR from the wrong repository when `--repo` is specified, fixing a potential integrity error in "Resolved by commit" comments for cross-repo issues.

### FEATURE: PR #1258 (2026-07-03)
Background: refactor(#1243): rename workflow "oracle" concept to next-step
Changes: Workflow docs now refer to the deterministic next-step advisory consistently by its script name, `next-step`; the informal "oracle" label has been retired across all current documentation.

### FEATURE: PR #1276 (2026-07-03)
Background: feat(#1263): require mandatory reason on WORKFLOW_RESET_FROM sentinel
Changes: The emergency workflow reset sentinel now requires a reason: use `<<WORKFLOW_RESET_FROM_{step}: {reason}>>` (example: `echo "<<WORKFLOW_RESET_FROM_write_tests: user requested re-plan>>"`). The bare form without a reason is rejected with guidance (reason must be at least 3 non-space characters, contain no `>`, and not be a placeholder like "none"). After updating, regenerate `~/.claude/settings.json` with `node install/assemble-settings.js` and restart Claude Code to activate the new permission rule.

### FEATURE: PR #1265 (2026-07-03)
Background: fix(#1215,#1242): run_tests evidence split + contract-trust completion
Changes: `run_tests` now completes only from `bash tests/run-all.sh` (which emits the trusted `RUN_CONTRACT` line) or the `/run-tests` skill sentinel. Ad-hoc or direct test commands (e.g. `pytest tests/`) no longer auto-complete the step — they demote it to `pending`. This closes false-green cases where a masked failing test run let the commit gate wrongly unblock.

### FEATURE: PR #1272 (2026-07-03)
Background: refactor(#1251): consolidate session-id resolvers into canonical chain + bin/resolve-session-id bridge
Changes: Session-id resolution is now consistent across all workflow tooling: every bash and Node CLI entry point delegates to the same canonical 7-step resolver via the new `bin/resolve-session-id` bridge. `CLAUDE_CODE_SESSION_ID` now takes precedence over `CLAUDE_ENV_FILE` / `CLAUDE_SESSION_ID` everywhere, fixing a class of wrong-session attribution when multiple Claude Code sessions run concurrently.

### FEATURE: PR #1281 (2026-07-03)
Background: refactor(#1275): split 3 oversized test files into dispatcher + fragments
Changes: Refactored 3 oversized test files (>500 lines) into dispatcher + fragment structure; no test behavior changed.

### FEATURE: PR #1282 (2026-07-03)
Background: feat(#513,#1198,#1048,#1237,#1096): companion pre-check rework + guard CLIs
Changes: clarify-intent now runs all companion checks (file overlap, keyword density, decomposition impact) before asking — presenting a single filtered batch instead of per-candidate prompts.;Companion reason tags now include `file:<basename>` and `kw:<n>` signals for richer accept/skip decisions.;Decomposition impact is shown in the main conversation alongside companion candidates, not buried in a confirmation dialog.

### FEATURE: PR #1298 (2026-07-04)
Background: feat(#1259): replace outline/detail isTrivial regex with orchestrator judgment
Changes: The orchestrator now judges whether to skip outline and detail planning stages by semantically reading intent.md / outline.md, replacing keyword-matching heuristics. Sessions with a single obvious approach skip planning automatically.

### FEATURE: PR #1299 (2026-07-04)
Background: docs(#1297): add agents terminology glossary (docs/glossary.md)
Changes: Added a terminology glossary (docs/glossary.md) that indexes workflow stage names and abbreviations, grouped by category and each linking to its canonical definition.

### FEATURE: PR #1304 (2026-07-04)
Background: feat(#1257): add SC-2C path for WF-META session-close
Changes: WF-META (planning-only) sessions now complete `/session-close` successfully. Final Report shows associated issues as "kept open (planning session)" instead of "failed".

### FEATURE: PR #1312 (2026-07-04)
Background: feat(#1292): add command-ir.js IR + classify() false-positive fixes (#876, #1223)
Changes: Fixed: `pwsh script.ps1 --out-file result.txt` and similar commands using `--out-file` as a CLI flag were incorrectly blocked by the worktree write guard; they now classify as read (#876).;Fixed: `git log path/to/reset/file.js`, `git diff -- src/reset/config.ts`, and similar commands where "reset" appears in a path argument were incorrectly blocked as git-reset operations; they now classify as read (#1223).

### FEATURE: PR #1313 (2026-07-04)
Background: feat(#1306): add cross-repo issue routing to workflow-init (L1 explicit tokens + L2 prose detection)
Changes: Cross-repo issue routing: `workflow-init` now handles issues from multiple repos in a single session — explicit `repo#N` or `owner/repo#N` tokens route all `gh` calls (WIP state, board card, label, closed-state check) to the correct repo for each issue.

### FEATURE: PR #1314 (2026-07-04)
Background: feat(#1303): proactive language-directive injection
Changes: Your configured conversation language (CONV_LANG) is now re-applied on every turn, so long sessions no longer drift back to English partway through.;While a plan is being written, the plan-artifact language (PLAN_LANG) is now steered proactively rather than only corrected after the plan is already written.

### FEATURE: PR #1302 (2026-07-04)
Background: feat: authoritative recorded-verdict skip for outline/detail stages
Changes: Outline/detail planning stages now auto-skip only when the orchestrator's recorded skip judgment passes full rubric validation and is stored as an auditable verdict; a partial or malformed judgment no longer skips planning (fail-safe). Refines the auto-skip introduced in #1298.

### FEATURE: PR #1322 (2026-07-04)
Background: feat(#1293): canary-2 — splitSegments fd-dup fix + shared-cmd-utils IR migration
Changes: POSIX fd-dup redirects (2>&1, 1>&2, >&2, N>&-, >&-) no longer cause false-block errors on worktree commands such as git merge 2>&1 or git pull --ff-only 2>&1. The enforce-worktree hook now recognizes these as redirect operators rather than shell-chaining operators at the parser level, permanently eliminating a class of false positives that recurred three times (#982, #838, #959).

### FEATURE: PR #1320 (2026-07-04)
Background: feat(#1308): make review-plan-security and review-tests Codex-primary
Changes: Security-plan and test-coverage reviews are now performed by Codex as the primary reviewer (with an automatic Claude Code fallback when Codex is unavailable), giving an independent second perspective on plan security and test completeness.

### FEATURE: PR #1326 (2026-07-05)
Background: feat(#1294): canary-3 — bash-write-scope.js IR consumption + dispatch parse-once
Changes: Hook layer now parses each Bash command once per tool call (IR threading). No user-visible behavior change — internal refactor for the #1253 IR migration series.

### FEATURE: PR #1334 (2026-07-05)
Background: feat(#1310): hasValidSkipJudgment stale-guard — bind recorded verdict to artifact mtime
Changes: Recorded-verdict skip now invalidates stale judgments after planning artifacts are re-generated. If the intent or outline document was edited after a skip judgment was recorded, the recorded verdict is now correctly treated as stale and the full planning step (outline or detail) runs again. Previously a stale record could authorize a skip even after the planning context changed.

### FEATURE: PR #1338 (2026-07-06)
Background: feat(#1337): add /workflow-off /workflow-on skills and pre-commit human bypass
Changes: `/workflow-off` and `/workflow-on` skills: suspend and restore workflow/worktree enforcement from a skill invocation.;`git commit` from a human terminal no longer blocked by `ENFORCE_WORKTREE`.

### CONFIG: Rename workflow enforcement toggle commands (2026-07-09)
Background: The /workflow-init command was hard to reach in autocomplete because the shorter /workflow-on and /workflow-off names ranked above it.
Changes: The /workflow-on and /workflow-off commands are renamed to /enforce-workflow-on and /enforce-workflow-off. They still restore and suspend workflow/worktree enforcement exactly as before — only the command name changed, so that /workflow-init is easier to reach in slash-command autocomplete.

### FEATURE: PR #1341 (2026-07-09)
Background: feat(#1340): add /issue-setup skill + issue-create auto-init for uninitialized repos
Changes: Added the `/issue-setup` command to initialize labels and a Projects v2 board on a new repo in one step.;`issue-create` now auto-repairs missing labels and prompts to create a missing project board when run against an uninitialized repo, instead of failing.;`sync-labels` gained a `--repo OWNER/REPO` option for cross-repository label sync.;Removed the `WIP_STATE_*` environment variables — Projects v2 field IDs are now resolved on demand per repository (delete them from your `.env`; the `wip-state setup` command is deprecated).

### FEATURE: PR #1348 (2026-07-10)
Background: fix(#1330): shared-IR test detection + harden git non-exec + review coverage
Changes: Fixed a bug where read-only commands that merely mention a test path inside a compound shell structure (e.g. `for f in tests/*.sh; do head "$f"; done`) could wrongly reset the workflow `run_tests` step to pending. Test-command detection now understands control structures and only reacts to real test runs.

### FEATURE: PR #1356 (2026-07-10)
Background: refactor(#1343): unify ENFORCE_WORKTREE_EXCLUDE into path-coverage model; rename EXTRA_REPOS→ADDITIONAL_REPOS
Changes: **`ENFORCE_WORKTREE_EXCLUDE`** now accepts both glob patterns (`*`, `**`) and plain path prefixes (covering a path and its whole subtree) in a single semicolon-separated list — `ENFORCE_WORKTREE_EXCLUDE_REPOS` is deprecated (a one-time warning guides migration).;**`ENFORCE_WORKTREE_EXTRA_REPOS`** renamed to **`ENFORCE_WORKTREE_ADDITIONAL_REPOS`** — old name still works with a deprecation warning.

### FEATURE: PR #1355 (2026-07-10)
Background: feat(#1180,#1278): add CODE_LANG commit-time language policy check + tests
Changes: New `CODE_LANG` setting: set to `english` or `japanese` to block commits containing staged text files that violate the language policy. Leave unset or set to `any` to disable (default, noop). See `.env.example` for details.

### FEATURE: PR #1359 (2026-07-11)
Background: feat(#1113,#1058): add Issues→Class-members coverage gate + structural detail existence gate
Changes: New structural gate blocks outline and detail plan assembly when `## Issues` has more entries than `## Class members`, or when a detail plan covers issues but contains no `## Steps` or `## Files to modify` section. The gate fires automatically — no configuration required — and re-prompts the planner once before halting.

### FEATURE: PR #1360 (2026-07-11)
Background: refactor(supervisor): compact output, CONV_LANG, alert pre-catch, Codex audit
Changes: EM Supervisor is quieter: `warning`/`notice` findings no longer produce per-tool advisories; advisories only appear for `error`-severity cumulative findings.;Supervisor block-reason text now follows `CONV_LANG` — if your session language is Japanese, supervisor output appears in Japanese.;New PreToolUse shim intercepts OFF-sentinel emit commands (WORKFLOW_OFF / WORKTREE_OFF) before execution and blocks them when the supervisor has active findings.;Scope-drift check added at the pre-merge stage: intent violations accumulated during the write-code phase are now reported before a PR is created, not only at Stop boundaries.;Audit mode now triggers on `warning`-severity cumulative findings (previously required `error`), catching potential scope drift sooner.

### FEATURE: PR #1362 (2026-07-11)
Background: fix(#1358): _encodeCwd ignores CLAUDE_PROJECT_DIR, uses cwd argument only
Changes: Fixed: sessions from another workspace no longer appear in the current workspace's CC sessions list when multiple Claude Code sessions run concurrently (caused by `_encodeCwd` incorrectly preferring `CLAUDE_PROJECT_DIR` over the explicit cwd argument).

### FEATURE: PR #1363 (2026-07-11)
Background: feat(#1336): add wip-state abandon verb + issue-state-check.sh
Changes: `wip-state.sh abandon <N>`: new verb for session abandonment — resets board Status to Todo and clears fingerprint; OPEN-only guard refuses to run on CLOSED issues (use `clear` for closed)

### FEATURE: PR #1370 (2026-07-11)
Background: feat(#1350): complexity evaluation SSOT — evaluate once at CI-C1b, persist to state.complexity_evaluation, read in MDP-3/WCD-3/WT-5
Changes: Model complexity routing (opus vs sonnet) is now evaluated once per session at intent-clarification time and reused consistently across all planning and coding stages, eliminating redundant re-evaluations that could produce inconsistent model selection.

### FEATURE: PR #1366 (2026-07-11)
Background: refactor(#1364): rename core-principles to CPR-N scheme + add CPR-3 Separate the Concerns
Changes: New reasoning principle CPR-3 "Separate the Concerns" added to core-principles.md — principles now use CPR-N identifiers (CPR-1 through CPR-8) for stable cross-references.;Removed outdated Stop hook that blocked merge approval when using the Bash Allow/Deny dialog flow (was enforcing a superseded AskUserQuestion-before-USER_VERIFIED design).

### FEATURE: PR #1373 (2026-07-11)
Background: fix(#1323): narrow UNSAFE_REASON_CHARS to allow bare  in sentinel reason
Changes: Sentinel echoes whose reason field contains bare `$VAR` tokens (e.g. `<<WORKFLOW_CONFIRM_INTENT: contains $VAR token>>`) are no longer false-blocked; the worktree write guard now correctly classifies them as "read".

### FEATURE: PR #1379 (2026-07-11)
Background: feat(#1351): add resolveSkipConditionsFromComplexity — auto-satisfy outline/detail skip conditions for 0-signal-sonnet sessions
Changes: Sessions with no complexity signals now automatically satisfy outline and detail skip conditions — no manual orchestrator judgment required for those sessions.

### FEATURE: PR #1386 (2026-07-12)
Background: refactor(#1382): complexity_evaluation stores level (high|low) instead of model name (opus|sonnet)
Changes: `complexity_evaluation` now stores complexity level (`high`/`low`) instead of model names (`opus`/`sonnet`). `read-complexity-evaluation` output changes from `verdict=opus|sonnet` to `level=high|low`. Existing sessions with recorded evaluations are automatically migrated via a backward-compat shim.

### FEATURE: PR #1388 (2026-07-12)
Background: fix(#1380): strip trailing shell redirects before enforce-worktree force-delete match (#1172)
Changes: Fixed: `/worktree-end` and `/sweep-branches` no longer fail to force-delete their feature branch when the underlying delete command carries a trailing shell redirect (e.g. `2>&1`, `>/dev/null`) or a quoted `-C` path that contains spaces.

### FEATURE: PR #1397 (2026-07-12)
Background: feat(#1392,#1352,#544,#1353): speculative-skip engine, scope-change detection, judgment rename, settings auto-allow
Changes: Speculative-skip verification: outline/detail skips now launch a background skip-verifier check; `next-step` blocks progress if the verifier hasn't returned and resets the plan stage if it vetoes.;Scope change detection in detail planning: class-member disposition changes, phase splits, or approach pivots relative to the outline now surface a warning before detail plan confirmation.;`WORKFLOW_OUTLINE_NOT_NEEDED` / `WORKFLOW_DETAIL_NOT_NEEDED` sentinels are now auto-allowed (no approval prompt required).

### FEATURE: PR #1403 (2026-07-12)
Background: feat(#1396): add severity/model classification labels; /issue-create auto-attaches model:* from system-prompt injection
Changes: `/issue-create` now auto-classifies `severity:high` (fatal: workflow stops, abort, loop, security hole) or `severity:low` (cosmetic/deferrable) based on issue content; no label = normal severity;New `model:fable` / `model:opus` / `model:sonnet` / `model:ds4` / `model:others` labels auto-attached by `/issue-create` based on which model is running the current session

### FEATURE: PR #1406 (2026-07-12)
Background: fix(#1391): remove classify() temp-path redirect gate; retire kind:"gh" WRITE_PATTERNS group (#1296 partial)
Changes: Fixed an enforce-worktree guard gap where a file redirect targeting a repository located under a system temp directory (e.g. `/tmp/`) was incorrectly treated as read-only and allowed past main-worktree write enforcement.

### FEATURE: PR #1409 (2026-07-12)
Background: feat(#1405): gate verification-gate ask behind RUN_E2E (off→skip / on→unchanged)
Changes: By default (RUN_E2E=off) the pre-commit/pre-merge verification-gate prompt — which asked whether you had verified a risk-category change in a real E2E environment — no longer appears. It was unactionable without an E2E environment set up. Set RUN_E2E=on to re-enable the prompt once you have one. When suppressed, the affected risk categories are still recorded to WORKTREE_NOTES.md ## Unverified Categories as a log-only trace.

### FEATURE: PR #1416 (2026-07-13)
Background: fix(#1166): rename alert_phase frozen→paused; introduce closed as permanent terminal phase
Changes: C2 supervisor review no longer re-fires after the Final Report is delivered — a spurious re-arm after `/session-close` set the session-close phase has been fixed.

### BUGFIX: PR #1417 (2026-07-13)
Background: fix(#882): extract session-bound worktree resolution into SSOT helper; wire RT-1/RT-4a to it
Changes: `/review-tests` now selects staged files from the session's linked worktree (not CWD) when run from the main-conversation context, fixing token mismatch at the pre-commit gate (#882).

### BUGFIX: PR #1418 (2026-07-13)
Background: PR #1418 merged on 2026-07-13.
Changes: Fixed: WORKTREE_OFF / WORKFLOW_OFF no longer blocks itself when re-used in the same session; the first use now records an audit event that the shim correctly ignores for subsequent off-sentinel checks

### FEATURE: PR #1420 (2026-07-13)
Background: feat(#1400,#1401): WRITE_PATTERNS→IR migration — retire green-group + git, typed write-target contract, fail-closed security convergence
Changes: Hardened main-worktree write-protection: git commands, shell redirects, PowerShell cmdlets, and file operations are now detected via IR-based analysis rather than surface-regex patterns. Exotic execution constructs (command substitution, eval, xargs, find -exec, process substitution) that attempt writes are fail-closed blocked. No change to user-visible allow/block outcomes for ordinary workflows.

### FEATURE: PR #1429 (2026-07-13)
Background: PR #1429 merged on 2026-07-13.
Changes: Session-close Final Report no longer dumps all supervisor findings in detail; shows a one-line count+severity summary instead (#1342);Pre-merge supervisor check no longer blocks when a fresh audit verdict (WARN/CONTINUE) already reviewed the findings; only BLOCK verdicts gate the merge (#1374)

### FEATURE: PR #1430 (2026-07-13)
Background: feat(#1145,#1404): WE-15 adaptive block message + cleanup-cascade/SKILL.md guardrails
Changes: `worktree-end`: When WE-15 (`git worktree remove`) fails due to a CWD lock or busy state, `WORKTREE_OFF` is not needed — `/sweep-worktrees` reclaims the worktree automatically. Follow the WE-16 fallback and continue to WE-20.

### FEATURE: PR #1433 (2026-07-13)
Background: feat(#1431): test-design.md progressive-disclosure split + Pattern 4 classifier coverage
Changes: Classifier/guard both-direction test coverage (Pattern 4) is now a documented standard in `test-design.md`; `write-tests` and `review-tests` now load `core-principles.md` to surface CPR-5 symmetry at tester context, preventing recurrence of the #1425 false-positive class

### FEATURE: PR #1434 (2026-07-13)
Background: feat(#1428): rename review-skill-size → review-prompt-size; extend to rules/*.md, agents/*.md, skills/_shared/*.md
Changes: `review-prompt-size` (renamed from `review-skill-size`) now enforces the 200-line hard limit on `rules/*.md`, `agents/*.md`, and `skills/_shared/*.md` in diff mode — not just `SKILL.md`.

### FEATURE: PR #1437 (2026-07-14)
Background: fix(#1435): block modified .env files in pre-commit (--diff-filter=AM)
Changes: Fixed: `pre-commit` hook now blocks commits of modified `.env` files (previously only newly-added `.env` files were caught).

### FEATURE: PR #1438 (2026-07-14)
Background: fix(#1436): exclude FD-to-FD redirects from isPosixRedirWriteIR write detection
Changes: Commands using `2>&1` or `>&2` (FD-to-FD redirects) no longer trigger a spurious write-block in the main worktree; regression from #1420.

### FEATURE: PR #1451 (2026-07-17)
Background: fix(#1443,#1442): WE-7/WE-8 linked-worktree CWD directives + CWD-independent session-ID fallback
Changes: Worktree-end (WE-7/WE-8) now explicitly keeps the working directory in the linked worktree until the final cleanup step, preventing the premature-switch errors that previously forced a second user-verified sentinel.;When a git command fails because a branch is already checked out in another worktree, a guidance message now points to the conflicting worktree and the commands to resolve it.;Workflow sentinels are now recognized as the same session whether emitted from the linked or the main worktree (session resolution no longer depends on the current directory).

### FEATURE: PR #1458 (2026-07-17)
Background: feat(workflow-init): consolidate WI-2..WI-9 into resumable Node.js driver
Changes: `/workflow-init` now runs its mechanical steps (issue fetch, WIP check, closed-issue handling, path routing) through a single resumable driver command — routing is deterministic across models, and an interrupted run resumes from a checkpoint instead of restarting.;Fixed: starting a session with a single issue and no existing work-in-progress claim no longer misreports the WIP state (previously the no-claim branch was unreachable and the session could skip the fresh-claim routing).

### FEATURE: PR #1459 (2026-07-17)
Background: fix(enforce-worktree): restore scratchpad-redirect and New-Item-Directory allow paths lost in PR #1420 IR-signature migration
Changes: Fixed a regression where sanctioned commands run from the main worktree were wrongly blocked as "write from main worktree": creating a worktree directory with `New-Item -ItemType Directory` (worktree setup) and `git worktree remove` now work again.;Fixed session-artifact and scratchpad writes (heredoc/redirect targeting the workflow plans directory or the temporary scratchpad) being wrongly blocked from the main worktree.

### FEATURE: PR #1460 (2026-07-17)
Background: feat(#1261): labels.yml SSOT propagation to sibling repos via CI
Changes: When `PROPAGATE_LABELS_PAT` secret is set, label changes in `.github/labels.yml` now automatically propagate to sibling repos (`dotfiles`, `my-private-repo`) via the new `propagate` CI job — sibling `labels.yml` files are overwritten with a GENERATED header to prevent direct edits.
### FEATURE: PR #1461 (2026-07-17) (2026-07-17)
Background: fix(#1450): reduce supervisor alert output to actionable-only findings
Changes: EM Supervisor alert reviews now surface only actionable findings (severity warning/error) as a single-line summary per finding instead of the full verbose report. Notice-level findings are recorded in the state file but not shown. A /issue-create hint is appended when the finding category suggests it. This reduces context window pollution in the main agent on every supervisor review.

### FEATURE: PR #1471 (2026-07-17)
Background: fix(#1255): supervisor reportBlock severity notice + block finding class dedup
Changes: Hook blocks no longer arm supervisor alert mode on their own — `reportBlock` severity is now `notice`, and repeated blocks from the same hook on the same command are collapsed into a single finding with a count field

### FEATURE: PR #1472 (2026-07-17)
Background: feat(#1411): pkg-mgr × 7 + interpreter-c IR migration + retire (canary-6a Phase 2)
Changes: Fix: chained interpreter commands (`bash -c '...'; sh -c 'rm file'`) were incorrectly fast-allowed from the main worktree — write bodies in subsequent segments were missed. Now correctly blocked.;Fix: `pwsh -command "..."` (lowercase flag) and `bash -lc "..."` (combined POSIX flag) were not detected as inline-script invocations and were incorrectly allowed from the main worktree. Now correctly blocked.

### FEATURE: PR #1477 (2026-07-17)
Background: feat(#1470): add check-inline-procedures quality gate to WF-CODE-6
Changes: New `check-inline-procedures` quality gate in WF-CODE-6: warns when prompt files contain inline numbered procedure blocks of 3 or more steps (advisory only, always exits 0).

### FEATURE: PR #1480 (2026-07-17)
Background: refactor(#1463): scriptify session-close/SKILL.md
Changes: Session close Final Report placeholders are now substituted by `bin/render-final-report.js` — no manual LLM token substitution required; all 13 section headings and field values are resolved deterministically.

### FEATURE: PR #1490 (2026-07-17)
Background: feat(enforce-worktree): report write predicate name in block reason
Changes: When `enforce-worktree` blocks a Bash write command, the block reason now names the detection predicate that fired (e.g. `Detected by: POSIX redirect or tee (isPosixRedirWriteIR)`), making it easier to diagnose unexpected blocks.

### FEATURE: PR #1489 (2026-07-17)
Background: fix(#1483): add missing scripts to enforce-worktree SANCTIONED allowlist
Changes: `/issue-create` can now be invoked from the main worktree when `ENFORCE_WORKTREE=on` — a missing allowlist entry caused every attempt to be blocked, generating supervisor warnings that then sealed the `WORKTREE_OFF` escape hatch.

### FEATURE: PR #1491 (2026-07-17)
Background: fix(#1145): narrow isWorktreeEndEnv() to WE-15..WE-22 cleanup window
Changes: Fixed: worktree-end supervisor adaptive guidance ("WE-15 cleanup in progress") no longer fires incorrectly in post-WE-22 contexts (e.g. /session-close); WORKTREE_OFF block message now uses correct fixed text after cleanup window closes.

### FEATURE: PR #1494 (2026-07-17)
Background: fix(enforce-worktree): write-detector false-negatives/false-positives (#1424 #1425 #1448)
Changes: `enforce-worktree`: fix three write-detector false-negatives/positives — sequenced `gh` write commands are now detected per-segment (#1424); multi-line `\`-continued commands no longer trigger false-positive write blocks (#1425); redirects to non-repo temp paths from a non-git CWD and compounds with trailing `; echo RC=$?` are no longer blocked (#1448).

### FEATURE: PR #1493 (2026-07-17)
Background: fix(#1482,#861,#1161): post-compact workflow progress + conv-lang any no-op + pr-merge reset_reason
Changes: Fixed `CONV_LANG=any` injecting "Respond to the user in any." instead of being a no-op — `any` is now treated like `english` (no injection).;After context compaction, the resumed conversation now shows a 10-step workflow progress summary (step names and statuses read directly from the session state file), preventing the assistant from re-doing completed steps.

### FEATURE: PR #1496 (2026-07-17)
Background: feat(#1492): rename model:* labels to reporter-model:*, add model-scope:* taxonomy
Changes: **Label taxonomy**: `model:*` labels renamed to `reporter-model:*`; new `model-scope:*` labels added for issues scoped to a specific model's behavior. Run `bin/github-issues/migrate-model-labels.sh --dry-run` to preview the GitHub migration.

### FEATURE: PR #1497 (2026-07-17)
Background: feat(#1487): add soft gh auth 'project' scope check to install.sh + install.ps1
Changes: `install.sh` and `install.ps1` now warn on completion when `gh` is installed and authenticated but lacks the `'project'` scope needed for Projects v2 and `/issue-create`. Run `gh auth refresh -s project` or `/issue-setup` to add it.

### FEATURE: PR #1502 (2026-07-17)
Background: fix(#1485): add bash/node prefix to direct call sites + chmod+x sweep on bin/
Changes: Fix: bin/ scripts now have the correct execute bit recorded in git (mode 100755); direct shebang-based invocation works on macOS, Linux, and WSL without needing a bash/node prefix

### FEATURE: PR #1505 (2026-07-17)
Background: fix(#1499): add ISSUE_TOKEN_CLI_GUARD_RE to parseIssueToken — reject bare digits
Changes: Fixed: `/workflow-init` no longer extracts spurious issue numbers from free-text tokens that contain bare digits (e.g. version strings like `bash 3.2` no longer match as issue `#3`).

### FEATURE: PR #1507 (2026-07-17)
Background: feat(#1492): sync-labels DELETE propagation + migrate pre-delete guard
Changes: sync-labels.sh now deletes labels absent from `.github/labels.yml`; `propagate-labels.sh` inherits this automatically for sibling repos;`--dry-run` flag added to `sync-labels.sh` (gates all mutations: CREATE, UPDATE, and DELETE);`migrate-model-labels.sh` Phase 1 pre-delete guard: safely clears zero-issue target labels before rename, fixing CI ordering issue that previously blocked issue association preservation

### BUGFIX: PR #1512 (2026-07-18)
Background: fix(#1488): validate workflow-init-driver raw-token args — reject newline/malformed tokens with NEXT_HINT
Changes: `workflow-init` now validates raw-token arguments before processing — multi-line text, prose, or malformed tokens are rejected with a clear `ACTION=blocked REASON= NEXT_HINT=` response. Improves compatibility with non-Claude-Code-native LLMs (e.g. DeepSeek V4 Flash) that may misinterpret the `<raw-tokens>` placeholder.

### FEATURE: PR #1513 (2026-07-18)
Background: fix(#1511): add PLAN_LANG directive to outline-planner, detail-planner, and clarify-intent
Changes: Planning agents (outline-planner, detail-planner, clarify-intent) now write plan artifacts in the language set by `PLAN_LANG` from the first write — eliminates the same-session re-write when `PLAN_LANG=japanese`

### FEATURE: PR #1515 (2026-07-18)
Background: fix(#923): enforce-worktree early-exit for git worktree remove/prune
Changes: `git worktree remove` and `git worktree prune` from the main worktree are now correctly allowed even when a `-C <path>` flag is used; a security boundary blocks the same commands from a linked worktree or when `-C` targets a different repo

### FEATURE: PR #1516 (2026-07-18)
Background: fix(#950): resolveSessionWorktreePath falls back to state.session_worktree for mid-session /worktree-start
Changes: `/review-tests` now works when the session was started from the main worktree and `/worktree-start` was run mid-session (exit-code-3 fixed).

### FEATURE: PR #1514 (2026-07-18)
Background: refactor(#1508): unify supervisor state key on CC UUID
Changes: Supervisor state key unified on CC UUID: `bin/supervisor-report` auto-resolve now uses CC UUID exclusively (via `CLAUDE_CODE_SESSION_ID` env var); `--mirror-session-id` flag removed. Downstream hooks (`supervisor-guard.js`, `stop-l2-findings-display.js`) simplified: wsid fallback shim removed, single-store read on CC UUID key.

### FEATURE: PR #1518 (2026-07-18)
Background: fix(enforce-worktree): remove wtCount upper-bound for skill-prefixed stash (#1024)
Changes: POSIX I/O redirects (`2>&1`, `N>&1`, `N>&-`) in sanctioned git commands no longer false-block `enforce-worktree.js` (#1115, #982).;`git -C <path> worktree remove/prune/add` now passes `enforce-worktree.js` from both main-worktree and linked-worktree CWDs (#923, #838).;Sanctioned worker scripts (`issue-close-stage-worker`, `commit-push-worker`, etc.) launched from the main worktree with linked-worktree path arguments no longer false-block (#959).;`WORKTREE_END_SKILL=1 git stash pop/drop/push` during `/worktree-end` WE-20 no longer false-blocks in repos with multiple linked worktrees (zombie worktree accumulation) (#1024).

### FEATURE: PR #1506 (2026-07-18)
Background: feat(#1498): add C4 premature-stop guard Stop hook
Changes: When Claude stops mid-workflow while a pending skill is waiting (ACTION=invoke), the new premature-stop guard Stop hook auto-resumes Claude and prompts it to run the pending skill.

### FEATURE: PR #1523 (2026-07-19)
Background: fix(#1509): close-not-planned.sh --reason flag value and isNotPlanned detection
Changes: Fixed `/issue-close-migrated` silently leaving issues OPEN: `close-not-planned.sh` passed `--reason not_planned` (underscore) but gh CLI requires `--reason "not planned"` (space); issues now close correctly.

### FEATURE: PR #1525 (2026-07-19)
Background: fix: scan-outbound trailing-newline guard, gh api write scanning, test stub regression check
Changes: Fix: `bin/scan-outbound.sh` no longer drops the last line of private-info allowlist/blocklist files that lack a trailing newline — blocklist enforcement and allowlist exemptions now apply to every pattern regardless of file format.;Fix: `hooks/scan-outbound.js` now scans `gh api` write requests (POST/PATCH/PUT/DELETE with `-f`/`-F`/`--field`/`--input @file`) for private information, matching the existing coverage for `gh issue`, `gh pr`, and similar commands.

### FEATURE: PR #1529 (2026-07-19)
Background: feat(#1384,#1522,#478,#1124,#1146,#1245): reduce outline planning friction — frontrunner-collapse, abolish MOP-7 dialog, PLAN_LANG directives, VS Code text visibility
Changes: Outline approach selection now requires only one confirmation (the outline approval step); the prior approach-selection dialog before that step is removed.;When one outline approach clearly dominates all alternatives on cost, risk, and fit, the planner now skips the approach menu automatically (frontrunner-collapse).;Plan files (`outline.md`, `detail.md`) are now written in the configured language (`PLAN_LANG`) from the first draft, avoiding redundant re-write cycles.
