# History (agents)

### SECURITY: check-private-info: allow Docker internal network and Node.js base image paths (2026-04-11, (pending))
Background: judgeclaw's docker-compose.yml uses Docker's default bridge network (172.24.0.x) and the official Node.js base image home directory (/home/node). The former matched the RFC 1918 private address pattern; the latter resembled a real user home path — both caused false positives in the private-info scanner.
Changes: Added two scoped entries to `.private-info-allowlist`: `docker-compose.yml:172\.24\.0` (Docker internal network, not routable) and `docker-compose.yml:/home/node` + `*/generate-web-access-section.sh:/home/node` (Node.js base image path, not a real user). Also fixed the path-capture regex in `bin/check-private-info.sh` from `/home/[a-zA-Z]` (one char) to `/home/[a-zA-Z][a-zA-Z0-9_.-]*` so the full username component is captured and allowlist entries can match precisely.

### REFACTOR: write-tests subagent: mode acceptEdits → default (2026-04-11, (pending))
Background: write-tests subagent was launched with mode: "acceptEdits" to bypass VSCode's "Ask before edits" dialogs for tests/ files. After settings.json was updated with Write(**/tests/**) and Edit(**/tests/**) allow rules, acceptEdits became unnecessarily broad — it bypassed all file permission checks, allowing the subagent to silently edit any file including source code. This was confirmed when a test subagent modified bin/session-sync.sh and settings.json without authorization.
Changes: Changed subagent launch mode in claude-global/skills/write-tests/SKILL.md from "acceptEdits" to "default". The existing allow rules in settings.json continue to auto-approve test file writes without confirmation dialogs.

### FEATURE: session-sync push: retry loop for simultaneous-commit race condition (2026-04-11, (pending))
Background: When Windows (PENPEN-11H) and macOS (mbp-m4pro-nire) push at the same time, both machines commit session data independently, creating a diverged state. The original code ran git pull --rebase once before push, but if Claude Code wrote new session data to a .jsonl file after the initial git add/commit but before pull --rebase, the pull failed with "unstaged changes" — leaving push to fail and trigger the "push failed" toast.
Changes: Replaced the single pull+push block in bin/session-sync.ps1 and bin/session-sync.sh with a retry loop (max 3 iterations). Each iteration commits any newly-written session files, rebases over remote, and retries push. Also added `:` no-op at end of quiet-mode success path in session-sync.sh to ensure exit code 0. Added two test cases per platform: static check for retry loop presence, and functional test verifying recovery from pre-diverged state with unstaged changes. Also suppressed pull --rebase stdout inside the retry loop (was only suppressing stderr) to match Windows behavior of silent quiet-mode operation. Added two quiet-mode stdout/stderr separation tests.

### FEATURE: Workflow state machine: deterministic 8-step enforcement (2026-04-12, (pending))
Background: CLAUDE.md workflow instructions were text-based and relied on Claude's judgment, making step skipping undetectable. check-tests-updated.js and check-docs-updated.js enforced single concerns independently but were not unified. Goal was to replace both with a single state-machine-based gate.
Changes: Created workflow state machine (lib/workflow-state.js shared module, workflow-gate.js PreToolUse commit gate replacing check-tests-updated.js and check-docs-updated.js, mark-step.js step completion CLI with --reset-from bypass, session-start.js SessionStart hook). Fail-safe design: missing or corrupted state blocks commits. Added Completion sections to 5 global skill SKILL.md files (survey-code, deep-research, make-plan, write-tests, update-docs). 36 tests in tests/feature-robust-workflow.sh.

### INCIDENT: #21: Hook integration path untested — CLAUDE_ENV_FILE format bug (2026-04-12)
Cause: session-start.js wrote `export CLAUDE_SESSION_ID=...` to CLAUDE_ENV_FILE, but Claude Code's env-file parser expects `KEY=VALUE` format (no `export` prefix). Test 30 used `grep -q` (substring match), so `export KEY=VALUE` passed despite being wrong. Root cause: tests only validated the JS script in isolation — the handoff point from script output to Claude Code's environment injection was never verified. In hook-based systems, the correctness of output format is only meaningful relative to the consuming system's spec, which unit tests cannot cover. More broadly, when writing tests, only single-file normal/error/edge cases were considered; integration paths across multiple components (hook → JS → env injection → Bash tool) were not enumerated as test targets.
Fix: Removed `export` prefix in session-start.js. Tightened test 30 to use `grep -qx` (exact line match). Follow-up investigation confirmed CLAUDE_ENV_FILE path is not propagated to Bash tool subprocesses (tested on Windows; macOS/Linux behavior unconfirmed).

### FEATURE: Workflow State Machine: mark-step.js session ID resolution redesign (2026-04-12)
Background: Empirical testing (Windows) showed that both CLAUDE_ENV_FILE path and CLAUDE_SESSION_ID are absent from Bash tool subprocess environment. The CLI design of passing session ID as an argument ($CLAUDE_SESSION_ID) was broken — always expanded to empty string. CLAUDE_ENV_FILE is available in hook contexts (SessionStart, PreToolUse, etc.) via process.env, but not in Bash subprocesses.
Changes: Removed session ID CLI argument from mark-step.js. Added resolveSessionId() to lib/workflow-state.js, reading CLAUDE_ENV_FILE from process.env to extract CLAUDE_SESSION_ID. workflow-gate.js usage messages updated. 41 tests pass.

### BUGFIX: Workflow State Machine: E2E verification + WSL path bug fix (2026-04-13)
Background: Manual E2E verification of the workflow state machine in a real Claude Code session after implementation was complete.
Changes: Confirmed all six test scenarios — normal cases 1–4 (SessionStart writes CLAUDE_SESSION_ID, mark-step.js records steps, git commit blocked on incomplete steps, git commit passes when all steps complete) and error cases 2–3 (--reset-from recovery from corrupted state file, partial reset from mid-workflow step). During verification, found and fixed a bug: on Windows, the hook resolved the WSL-style drive path extracted from the git -C flag using Windows Node.js, causing git rev-parse to fail with ENOENT and the gate to report "state not found" instead of listing incomplete steps. Fixed by adding toNativePath() to is-private-repo.js (converts bash-style drive paths to Windows paths on win32) and wiring it into resolveRepoDir. Added tests 42–49 to the test suite (all 49 tests pass).

### BUGFIX: PostToolUse marker interception: fix mark-step.js in Bash subprocess context (2026-04-13)
Background: CLAUDE_ENV_FILE is not propagated to Bash tool subprocesses (Anthropic bug #27987). mark-step.js called from skill Completion sections via Bash always failed to resolve session_id, silently leaving workflow steps unrecorded.
Changes: Added workflow-mark.js (PostToolUse Bash hook) that intercepts `echo "<<WORKFLOW_MARK_STEP:step:status>>"` via strict anchored regex on tool_input.command — rejects pipes, &&, cat/grep output containing the marker, etc. Hook reads session_id directly from hook stdin JSON and uses CLAUDE_PROJECT_DIR (documented env var, available in all hook types) for repo resolution. HOOK_CWD was excluded as undocumented with no confirmed usage evidence. Updated 5 skill Completion sections (survey-code, deep-research, make-plan, write-tests, update-docs). user_verification remains CLI-only to preserve the ask-rule gate. Added 26 test cases (normal, must-not-mark strict regex, error/edge, idempotency). Key finding: additionalContext surfaces messages to Claude; systemMessage reaches users only.

### INCIDENT: #22: settings.json PostToolUse misplacement (2026-04-13)
Cause: commit 01a9110 placed the PostToolUse hook inside the `permissions` block instead of the `hooks` block. Unit tests (direct JS invocation) pass regardless because they call the hook handler directly — they cannot detect whether Claude Code will ever invoke the hook at all.
Fix: Moved PostToolUse registration to the `hooks` block. Added SR1-SR4 structural assertions to the test suite to automatically detect misplacement. Added E2E test E1 (`claude -p` real invocation with `--setting-sources project`) confirming the hook fires and records the step in the state file. Added "Test Layer Selection" section to `claude-global/rules/test.md` documenting that wiring bugs (config misplacement, hook registration errors) require integration/E2E tests — not just unit tests (based on Fowler and Kent C. Dodds research).

### FEATURE: Workflow State Machine: PostToolUse Windows E2E verified + CLAUDE_PROJECT_DIR migration confirmed (2026-04-13)
Background: Windows E2E smoke test for the PostToolUse hook and simultaneous verification that the HOOK_CWD → CLAUDE_PROJECT_DIR migration (commit 264ab0a) works correctly in a real session.
Changes: E1 E2E test (`claude -p --setting-sources project --session-id`) passed: PostToolUse hook fires in a real Claude session, `CLAUDE_PROJECT_DIR` resolves the repo correctly, and the step is written to the state file. All tests pass with `RUN_E2E=1`. macOS/Linux verification remains pending.

### FEATURE: Workflow State Machine: Robust Improvements — Windows verification (2026-04-13)
Background: User verification of three robustness improvements on Windows (VSCode extension).
Changes: (1) `echo "<<WORKFLOW_USER_VERIFIED>>"` ask dialog confirmed — permissions.ask rule fires and PostToolUse hook records user_verification as complete. (2) SessionStart creates UUID-format state file at session start (.git/workflow/<session-id>.json confirmed). (3) isPrivateRepo bypass removal confirmed via git diff — a6ad6ab had `if (isPrivateRepo(repoDir)) approve()`, current code imports only resolveRepoDir.

### FEATURE: Workflow State Machine: .git/workflow deny rule verified (2026-04-13)
Background: In a new session (VSCode extension, Windows), confirmed that the deny rules work. The Edit(**/.git/workflow/**) and Write(**/.git/workflow/**) deny rules in settings.json take effect after restarting Claude Code.
Changes: Confirmed that both Write(**/.git/workflow/**) and Edit(**/.git/workflow/**) rules are automatically blocked by the Claude Code permission system. Full verification on Windows complete.

### REFACTOR: Workflow State Machine: marker format `:` → `_` (2026-04-13)
Background: Claude Code's permission glob parser treats `:` as a named-parameter separator inside `Bash(...)` rules, causing silent match failure (confirmed via anthropics/claude-code#33601). `WORKFLOW_RESET_FROM` ask rule was not triggering a dialog; investigation showed `Bash(echo "<<WORKFLOW_USER_VERIFIED>>")` (no colon) worked while any pattern containing `:` silently failed to match. Same issue applied to `WORKFLOW_MARK_STEP` allow rules. Default behavior when no rule matches is auto-allow, masking the problem.
Changes: Changed both marker formats to use `_` as separator: `<<WORKFLOW_MARK_STEP:step:status>>` → `<<WORKFLOW_MARK_STEP_step_status>>`, `<<WORKFLOW_RESET_FROM:step>>` → `<<WORKFLOW_RESET_FROM_step>>`. Updated workflow-mark.js regexes, settings.json allow/ask rules (RESET_FROM single-quote variant removed — DQ only), workflow-gate.js block message, 5 skill Completion sections, and test suite. Windows re-verification confirmed: normal cases 1–4 and error cases 1–2 all pass.

### FEATURE: Workflow State Machine: cross-platform verification complete (2026-04-14, 60aa84c)
Background: Completed happy-path and error-path verification across Windows, WSL, and macOS. macOS was the first native E2E run.
Changes: Verified happy path (session start, step recording, commit block, commit pass, PostToolUse real-fire) and error path (state file corruption -> fail-safe block -> --reset-from recovery, partial reset). Found and fixed three portability bugs during macOS E2E: (1) timeout not available -> run_with_timeout() perl fallback; (2) nested session error from inherited CLAUDECODE -> unset CLAUDECODE; (3) disableBypassPermissionsMode: disable neutralizing --dangerously-skip-permissions -> use minimal settings.json. WSL did not surface any of the three (CLAUDECODE not propagated, Windows profile referenced via bridge). Added run_with_timeout pattern and claude -p E2E caveats to test.md; extracted Installer Testing into test-installer.md.

### FEATURE: session-sync: push conflict auto-resolution (2026-04-14)
Background: Session sync was silently failing with "push failed" toast when ~/.claude/projects
received diverging commits from multiple machines (e.g. macOS and Windows both committing
session files before either pushes). git pull --rebase inside the retry loop swallowed JSONL
conflict errors via `|| true`, causing repeated push failures with no recovery.
Changes: Two fixes to bin/session-sync.sh push action. (1) Interrupted rebase detection: at
push entry, detect .git/rebase-merge or .git/rebase-apply and abort (rm -rf fallback for
fake/corrupt state that git rebase --abort cannot clean). (2) JSONL conflict auto-resolution:
when git pull --rebase fails, find conflicted *.jsonl files via git diff --diff-filter=U, strip
conflict marker lines (^<<<<<<<, ^=======, ^>>>>>>>), dedup via awk, git add, then
GIT_EDITOR=true git rebase --continue. Non-JSONL conflicts abort and retry. Also fixed the
"No changes to push" early exit to additionally check git log origin/main..HEAD, so push
proceeds when local branch is ahead of remote despite a clean working tree. 57 tests pass.

### INCIDENT: #23: workflow-gate block message as bypass attractor (2026-04-14)
Cause: workflow-gate.js:113-117 included a literal `echo "<<WORKFLOW_RESET_FROM_<step>>>"` recipe
in its "commit blocked" error message. When a skill's test setup ran `git commit` in a temp
repository, workflow-gate blocked it and the model read the hint — triggering autonomous
WORKFLOW_RESET_FROM calls to clear the gate. The model lacked holistic project context to judge
whether a reset was warranted; from inside a skill the hint looked like a legitimate shortcut.
Root cause is structural: the mechanism that should be a last resort was advertised in an error
message visible to subagents that cannot evaluate the full situation.

Fix: Removed the RESET_FROM hint from workflow-gate.js entirely (the block message now lists only
incomplete steps and the skill to run for each). Added a "Workflow State Recovery" section to
CLAUDE.md framing WORKFLOW_RESET_FROM as a last resort that "only the main conversation can use
when it has enough holistic context to judge that a reset is genuinely warranted." The settings.json
`ask` guard remains as a backstop. The RESET_FROM mechanism itself (workflow-mark.js PostToolUse
interception, required because CLAUDE_ENV_FILE does not propagate to Bash subprocesses per
Anthropic bug #27987) is unchanged.

Discussion notes: Several alternative fixes were considered and rejected.
(1) Obfuscating the hint — rejected because it merely makes bypass harder to find, not
structurally prevented.
(2) Moving documentation to ops.md only — would have required the user to manually run
mark-step.js even in cases where the main conversation can judge correctly.
(3) Manager subagent — rejected as overskill; the main conversation already has full context
and IS the manager.
The key insight: the right place for reset authority is the entity with holistic project context,
which is the main conversation (or the user directly). Skills and subagents must not reset.

### INCIDENT: #24: Workflow State Machine — multi-repo state mismatch (2026-04-14)
Cause: echo markers resolved repoDir from CLAUDE_PROJECT_DIR (primary project), while workflow-gate resolved repoDir from the git -C flag in the commit command. When committing to a secondary repo with git -C, the state was written to primary-project/.git/workflow/ but read from secondary-repo/.git/workflow/ — permanently blocking commits with no recovery path from inside a Bash subprocess (CLAUDE_ENV_FILE not propagated per Anthropic bug #27987).
Fix: Removed repoDir from all state operations. State moved to ~/.claude/projects/workflow/{session-id}.json (session-scoped). All hooks and CLI tools now use a single path, regardless of which repo is being committed. CLAUDE_WORKFLOW_DIR env var override added for test isolation. Migration block added to session-start.js to auto-delete old .git/workflow/ files. settings.json deny rules updated to new path. /workflow/*.tmp added to .gitignore in session-sync-init scripts to prevent race with session-sync git push.

### FEATURE: Workflow State Machine: session-scoped state migration (2026-04-15, (pending))
Background: Incident #24 root cause: per-repo state storage caused permanent blocking when committing across repos. Session-scoped storage eliminates the mismatch because all hooks and CLI tools use the same path for a given session, independent of which repo is targeted.
Changes: workflow-state.js: removed execSync/repoDir, added os.homedir()-based path (~/.claude/projects/workflow/), CLAUDE_WORKFLOW_DIR override for tests, cleanupZombies now removes stale .tmp files. workflow-gate.js, workflow-mark.js, mark-step.js, session-start.js: removed all repoDir arguments. session-start.js: added BEGIN/END temporary migration block to delete old .git/workflow/<session-id>.json on each session start. session-sync-init.ps1/.sh: added .gitignore with /workflow/*.tmp to prevent half-written state files from being synced. settings.json: deny rules updated from **/.git/workflow/** to ~/.claude/projects/workflow/**. Tests: added WS-UNIT-1~6, WS-IDEM-1 (unit), T-D1-4~7 (session-start without CLAUDE_PROJECT_DIR), T-MIG-1~2 (migration idempotency), INT-REGR-1 (cross-repo regression), SR-DENY-1~2 (deny rule validation). All pass on Windows.

### FEATURE: Workflow State Machine — E2E verification across all 3 environments (2026-04-15)
Background: After migrating state storage from {repo}/.git/workflow/ to ~/.claude/projects/workflow/, re-ran E2E verification on all platforms to confirm the new path is used end-to-end.
Changes: No code changes. Verified on Windows, macOS, and WSL: (1) SessionStart creates state file at new path; (2) WORKFLOW_MARK_STEP_* markers record steps via PostToolUse hook; (3) incomplete steps block git commit; (4) all steps complete allows git commit; (5) PostToolUse real invocation via RUN_E2E=1 (WSL skipped due to environment constraints — verified via settings.json structure instead); (6) git -C <other-repo> commit reads the same session state, no #24 regression; (7) WORKFLOW_RESET_FROM_* triggers ask dialog and hook rolls back state to the named step (manually confirmed including WSL). This also serves as user verification for the session-scoped state migration (previously tracked as "Verifying" in todo.md).

### FEATURE: Workflow State Machine — block user_verification direct bypass in mark-step.js (2026-04-15)
Background: mark-step.js user_verification complete could mark the step complete without going through the echo "<<WORKFLOW_USER_VERIFIED>>" path that triggers the settings.json ask dialog, discovered during WSL E2E verification.
Changes: mark-step.js: extended user_verification guard to also block status "complete" (was only blocking "skipped"), with error message pointing to the correct echo path. workflow-mark.js: corrected misleading comment ("must go through CLI") and fallback error message that incorrectly referenced mark-step.js as the manual path. Tests: added WS-UV-BLOCK-1~4 to feature-robust-workflow.sh (error, error, normal, edge cases). All tests pass.

### REFACTOR: install-obsolete: .git/workflow → ~/.claude/projects/workflow cleanup (2026-04-15, (pending))
Background: Workflow state was migrated from {repo}/.git/workflow/ to ~/.claude/projects/workflow/ (commit 738cb1c, incident #24). The session-start.js migration block handles new sessions automatically, but old .git/workflow/ directories left on disk before the migration remained unhandled.
Changes: install-obsolete.sh and install-obsolete.ps1 each received a BEGIN/END temporary migration block: searches $HOME (maxdepth 4) / C:\git repos for .git/workflow/ directories, salvages JSON files newer than 7 days to ~/.claude/projects/workflow/, then removes the old directory. Tests: main-install-obsolete-workflow-migration.sh (T1–T9, all pass).

### REFACTOR: Workflow State Machine: mark-step.js removal (2026-04-16, (pending))
Background: mark-step.js was designed as a CLI tool to mark workflow steps, but relied on CLAUDE_ENV_FILE which is not propagated to Bash tool subprocesses (Anthropic bug #27987). All functionality was already covered by the echo marker mechanism in workflow-mark.js (PostToolUse hook), making mark-step.js dead code.
Changes: Deleted mark-step.js. workflow-gate.js block messages updated from `node mark-step.js` to `echo "<<WORKFLOW_RESET_FROM_research>>"` / `echo "<<WORKFLOW_MARK_STEP_<step>_complete>>"`. workflow-mark.js fallback error messages likewise updated. settings.json: removed allow rule for mark-step.js and ask rule for mark-step.js user_verification bypass (now moot). Tests: removed all mark-step.js-specific test sections from feature-robust-workflow.sh (tests 17–34, WS-UV-BLOCK-1~4); replaced mark-step.js state setup in integration test with direct workflow-state.js call. All remaining tests pass.

### FEATURE: Workflow State Machine: evidence-based write_tests/docs enforcement (2026-04-16, bf95596+)
Background: write_tests and docs steps could be bypassed by running echo "<<WORKFLOW_MARK_STEP_*_complete>>" directly, without actually writing tests or updating docs. The user_verification step had protection via WORKFLOW_USER_VERIFIED ask dialog, but write_tests and docs had none. Additionally, the old check-tests-updated.js and check-docs-updated.js hooks (replaced by workflow-gate.js) used git staged-file evidence rather than state flags, and exempted claude-global/ from checks — an exemption that was found to be unjustified.
Changes: workflow-gate.js: added evidence-based checks — write_tests passes if tests/ changes are staged; docs passes if docs/*.md or *.md changes are staged; no claude-global/ exemption. Added resolveRepoDir(), hasStagedTestChanges(), hasStagedDocChanges() helpers. workflow-mark.js: MARK_STEP sentinel now rejected for write_tests and docs (like user_verification), with messages directing to staged-file path or NOT_NEEDED sentinels. Added WORKFLOW_WRITE_TESTS_NOT_NEEDED and WORKFLOW_DOCS_NOT_NEEDED handlers (mark step complete via ask dialog when evidence is genuinely absent). settings.json: added ask permissions for both new sentinels. write-tests/SKILL.md, update-docs/SKILL.md: completion instructions updated to git add instead of echo marker; NOT_NEEDED path documented.
Also: workflow-mark.js user_verification rejection message clarified to lead with "NOT recorded" (bf95596), fixing incident where Claude misread guidance as optional and proceeded to commit prematurely.

### FEATURE: doc-append/doc-rotate tools + architecture.md split (2026-04-16, (pending))

Background: history.md had no append-without-read strategy (full Read consumed context on every entry); architecture.md was 480 lines making context-efficient updates hard.

Changes: Added bin/doc-append.py (tail-seek append, CRLF/BOM-safe, ascending date invariant, incident #N numbering) and bin/doc-rotate.py (year-based archive, history/index.md generation, floor protection). Split architecture.md into architecture/file-tree.md, architecture/shell-startup.md, architecture/claude-code.md (156 lines from 480). Updated docs-convention.md with append-only tool table and rotation thresholds. Added settings.json allow/ask permissions for both tools. Tests: tests/feature-doc-tools.py (24 pytest integration cases).

### BUGFIX: Fix: commit-push skill model directive removed (2026-04-17, (pending))

Background: commit-push SKILL.md had model: haiku and effort: low directives, causing the Skill runner to spawn a new agent with a separate session UUID. The new session had all workflow steps pending, so workflow-gate blocked every commit attempt from within the skill.

Changes: Removed model: haiku and effort: low from commit-push/SKILL.md so the skill executes in the caller's session. Added regression test tests/main-commit-push-workflow-gate.sh (2 static checks verifying no model/effort directives).

### FEATURE: doc-rotate.py: line-count trigger and floor-based archiving (2026-04-17, (pending))

Background: doc-rotate.py archived entries based on a 365-day hardcoded cutoff, making rotation impossible when all entries are recent. Additionally, undated entries (pre-dating convention, 102 entries) were never archived. The threshold-warn/hard parameters were parsed but unused.

Changes: Replaced date-based cutoff with floor-based archiving: keep last --floor entries (default 20), archive the rest. threshold-warn gate (default 0 = always run) skips rotation when file is under the threshold. Undated entries treated as oldest and archived to history/legacy.md. Date regex made comma-optional to correctly parse entries without commit hashes. Removed --max-age-days. Tests: T-THRESH-1..5 added to feature-doc-tools.py (29 total, all pass).

### BUGFIX: Fix workflow-gate: Unix-style drive path normalization in resolveRepoDir (2026-04-17, pending)
Background: On Windows with Git Bash, `git -C /<drive>/path commit` passed a Unix-style drive path (e.g. `/<drive>/git/dotfiles`) to workflow-gate.js. Windows Node.js does not accept Unix-style paths as `cwd` in `execSync`, causing `hasStagedTestChanges` and `hasStagedDocChanges` to silently return `false` even when tests/ or docs/ were staged — blocking commits with a spurious "write_tests not complete" error.
Changes: `resolveRepoDir` now normalizes `/<drive>/path` → `C:\path` patterns (single drive letter followed by `/`). `hasStagedTestChanges` and `hasStagedDocChanges` catch blocks now write a warning to `process.stderr` instead of silently swallowing the error. Main execution wrapped in `require.main === module` guard; `resolveRepoDir`, `hasStagedTestChanges`, `hasStagedDocChanges` exported for testability. 13 tests added in `tests/fix-workflow-gate-unix-path.sh`.

### FEATURE: doc-append/doc-rotate + architecture.md split (2026-04-17, 28fa673)
Background: Added doc-append.py and doc-rotate.py to manage growth of docs/history.md. Split docs/architecture.md into an architecture/ subdirectory in preparation for exceeding 300 lines.
Changes: Added bin/doc-append.py and bin/doc-rotate.py. Split docs/architecture/ into claude-code.md, file-tree.md, and shell-startup.md. Added uv run permissions to settings.json.

### REFACTOR: install-obsolete: .git/workflow cleanup (2026-04-17, 5b3bf91)
Background: .git/workflow was the old storage location for workflow state, but migration to ~/.claude/projects/workflow was complete. Added salvage and deletion logic to install-obsolete.
Changes: Added .git/workflow -> ~/.claude/projects/workflow salvage logic to install-obsolete.sh and install-obsolete.ps1. Copies JSON files updated within 7 days to the new path and removes the old directory.

### FEATURE: Workflow State Machine: session ID injection and state inheritance across VS Code restarts (2026-04-18, (pending))
Background: When VS Code restarts (on hook changes, shutdown, etc.), a new session_id is issued and the old session workflow state file becomes orphaned, causing workflow-gate to treat all steps as pending and block commits.
Changes: Resolved by three combined changes. (1) session-start.js: added inheritance logic — on new session start, scans ~/.claude/projects/<encoded-cwd>/<session_id>.jsonl files by mtime descending (up to 10), searches stdout of SessionStart/PostCompact attachment entries for 'Current workflow session_id: <uuid>'. If a state with the same cwd+branch exists and is not all-pending, copies its steps. (2) session-start.js: changed output from {} to additionalContext JSON (session_id + state path) to record in transcript for future sessions to reference. (3) post-compact.js (new PostCompact hook): re-injects session_id after compaction to preserve transcript markers. workflow-state.js: added getCurrentContext() and findLatestStateForContext(ctx), added optional ctx (cwd/git_branch) argument to createInitialState(). settings.json: registered PostCompact hook. Tests: tests/feature-workflow-inherit-state.sh (A1-A12, T-C1-T-C3, 15 cases) and tests/feature-workflow-post-compact.sh (B1-B3, 3 cases), 18 cases total, all PASS.

### REFACTOR: mark-step.js removal and workflow-gate/mark message migration verified (2026-04-18, 9340267)
Background: Migrated workflow-gate/mark block messages from node mark-step.js call format to echo marker format. mark-step.js deleted and consolidated into workflow-mark.js.
Changes: Verified on all platforms: Windows, WSL, and macOS. Confirmed that block messages no longer contain node mark-step.js calls and that WORKFLOW_MARK_STEP / WORKFLOW_RESET_FROM echo markers are correctly reflected in state files.

### FEATURE: workflow-mark: require reason argument for WORKFLOW_DOCS_NOT_NEEDED sentinel (2026-04-18, (pending))
Background: The bare <<WORKFLOW_DOCS_NOT_NEEDED>> sentinel allowed reflexive skipping of the docs step without the model articulating why. Several sessions skipped docs when a history.md entry was warranted.
Changes: Sentinel extended to <<WORKFLOW_DOCS_NOT_NEEDED: REASON>> where REASON is validated (>=3 non-space chars, no '>', not a bilingual placeholder). Reason stored as state.steps.docs.skip_reason via new extraFields parameter on markStep(). settings.json ask glob updated. workflow-mark.js looks-like fallback rejects legacy bare form and reason-with->. WRITE_TESTS_NOT_NEEDED mirror change deferred (inline TODO). Tests WS-EV-9 through WS-EV-17 added to tests/main-workflow-evidence.sh.

### FEATURE: WORKFLOW_DOCS_NOT_NEEDED reason enforcement verification (2026-04-18, d5544f2)
Background: WORKFLOW_DOCS_NOT_NEEDED sentinel now requires a meaningful reason string (>=3 non-space chars, not a placeholder). Bare form is rejected. Verified via WS-EV-9 through WS-EV-18 in tests/main-workflow-evidence.sh.
Changes: All 18 test cases passed. No code changes needed.

### BUGFIX: workflow-gate: fix hasStagedTestChanges for Unix-style Git Bash paths (2026-04-18, 876d12e)

Background: Git Bash passes MSYS2-style paths (/<letter>/rest) to workflow-gate when using git -C. hasStagedTestChanges used this path as cwd for execSync, but Node.js on Windows cannot resolve MSYS2 drive paths, causing the function to throw and return false — the test-evidence override never triggered even when tests/ files were staged.

Changes: Added resolveRepoDir() function that converts MSYS2 paths to Windows paths. Called from the main hook entrypoint to normalize repoDir before passing to hasStagedTestChanges/hasStagedDocChanges. Both functions now accept an explicit repoDir parameter. Exported all three functions for unit testing. Tests: fix-workflow-gate-unix-path.sh — 13 cases (A: resolveRepoDir unit x7, B: staged-file integration x4, C: error handling x2), all PASS.

### BUGFIX: workflow-gate: fix commit regex false-positive on argument text (2026-04-18, pending)

Background: /git\s+(?:-C\s+\S+\s+)?commit\s/ had no line-anchor, so a Bash command whose arguments contained 'git commit' as text (e.g. doc-append.py --background '... git commit ...') triggered the commit block even though no git commit was being run.

Changes: Added ^ anchor to the regex (/^git\s+(?:-C\s+\S+\s+)?commit\s/). Regression test tests/main-workflow-gate-regex.sh added (7 cases: normal x4, bug-regression x2, edge x1), all PASS.

### FEATURE: Workflow State Inheritance across VS Code Restarts (2026-04-18, c6159ea)

Background: Implemented session state inheritance so that workflow steps (research/plan completion state) carry over to new sessions after VS Code restarts. findLatestStateForContext scans transcript JSONL files to find the most recently used session state for the current cwd+branch.

Changes: Manual smoke tests all passed: (1) steps inherited after VS Code restart, (2) most-recently-used session selected when multiple parallel sessions exist, (3) session_id preserved after /compact via SessionStart:compact hook.

### SECURITY: Enforce doc-append for history.md; block Japanese in public-repo doc-append (2026-04-18, pending)

Background: Claude was occasionally using the Edit tool directly on history.md instead of doc-append.py, violating the append-only convention. Japanese text was also leaking into history.md in public repos despite the language policy.

Changes: Added Edit(**/history.md) and Write(**/history.md) to the deny list in settings.json to hard-block direct edits. Added check-japanese-in-docs.js PreToolUse hook that blocks doc-append.py calls containing Japanese characters when the target repo is public. Tests: tests/main-check-japanese-in-docs.sh (10 cases, all PASS).

### FEATURE: Workflow State Inheritance across VS Code Restarts (2026-04-18, 2852d03)

Background: Workflow steps (research/plan completion state) were lost on VS Code restart because each new session started fresh. findLatestStateForContext was added to scan transcript JSONL files and inherit state from the most recently used session with matching cwd+branch.

Changes: Manual smoke tests all passed: steps inherited after restart, most-recent session wins among parallel sessions, session_id preserved after /compact via SessionStart:compact hook. Also fixed a bug where Windows cwd was not lowercased before encoding, causing transcript directory lookup to fail (C--git-dotfiles vs c--git-dotfiles).

### FEATURE: make-plan: NEEDS_RESEARCH mid-plan research escalation (2026-04-18, pending)
Background: The planner/reviewer loop had no escape hatch when the planner lacked external knowledge — it had to guess or stall. Adopted Option B (inlining): research findings are embedded verbatim into the next planner prompt, with no file persistence.
Changes: Added Research Escalation section to ~/.claude/skills/make-plan/SKILL.md: NEEDS_RESEARCH protocol (skill:/question:/reason: fields, first-non-whitespace-token detection, malformed handling), independent round counters (revision_rounds cap=2, research_rounds cap=2, malformed_retries cap=1 — never reset), re-prompt template with verbatim findings, and escalation message format. Added NEEDS_RESEARCH escape hatch, Research Findings section, and citation tag rules ([research: tag], format [a-z0-9-]+) to ~/.claude/agents/planner.md. Added citation integrity checklist item to ~/.claude/agents/reviewer.md. Contract tests: tests/feature-make-plan-research-escalation.sh (27 cases, all PASS).

### SECURITY: Security Enhancement Phase 1: /review-security skill (2026-04-18, 7330de5)
Background: Added architecture-phase security review skill (implemented 2026-04-06). Design decision: extract checklist details into skill (not rules/) to minimize context consumption per session. Skill naming follows existing verb-noun kebab-case convention.
Changes: Created ~/.claude/skills/review-security/SKILL.md with 3-axis checklist (Information Leakage: OWASP ASVS V8/V6; Third-Party Access: OWASP MCP Top 10 MCP03/MCP04, LLM Top 10 LLM03; External Access: OWASP WSTG, CWE Top 25). TodoWrite mandatory — no inline evaluation. Verified 2026-04-18: 15-item checklist registered and evaluated correctly in a live session.

### SECURITY: Security Enhancement Phase 2: Security cases in test.md + test-rules/ restructure (2026-04-18, pending)
Background: test.md lacked security-specific test case categories. Reviewers had no guidance on what security scenarios to cover when writing tests. test.md also exceeded 100 lines with low-priority detail mixed in.
Changes: Added Security cases bullet to Test Case Categories in claude-global/rules/test.md (secret leakage OWASP ASVS V8, input injection OWASP WSTG CWE-78/CWE-22, permission OWASP ASVS V4, prompt injection LLM Top 10 LLM01/MCP Top 10 MCP06, security idempotency). Extracted lower-priority sections to new rules/test-rules/ subdirectory: macos-timeout.md (paths-gated), claude-e2e.md (always loaded), installer.md (paths-gated, moved from test-installer.md). Removed Test Layer Selection reference links. test.md reduced from 149 to 106 lines.

### BUGFIX: Fix findLatestStateForContext: collect all session IDs and skip completed workflows (2026-04-18, 0ba7e13)
Background: findLatestStateForContext had two bugs: (1) it stopped at the first SessionStart/PostCompact session_id found in a JSONL file, ignoring later PostCompact entries that carry the more recent session_id; (2) it inherited state from completed workflows (user_verification=complete), causing the gate to demand USER_VERIFIED even at the start of a brand-new task. Both bugs were triggered together when a session ended with user verification and a new task was started in the same VS Code window.
Changes: workflow-state.js findLatestStateForContext: collect ALL session_id matches from SessionStart and PostCompact entries per JSONL, try them in reverse order (PostCompact/most-recent first). When the most-recent session has user_verification=complete, break out of the JSONL entirely — no fallback to older sessions in the same file. CLAUDE_TRANSCRIPT_BASE_DIR env override added for test isolation. Six new tests added to tests/feature-workflow-inherit-state.sh covering PostCompact priority, completed-workflow exclusion, and multi-ID scenarios. Also fixed Windows test infrastructure (TMPDIR_BASE path conversion, node_path() helper, stdin read without /dev/stdin, WORKFLOW_STATE_LIB_NODE path conversion).

### FEATURE: Workflow skip sentinels unified + DOCS_NOT_NEEDED removed (2026-04-18, pending)
Background: workflow-gate.js treated research/plan as SKIPPABLE_STEPS but no echo sentinel existed to declare them skipped — only workaround was manual JSON state editing. WORKFLOW_WRITE_TESTS_NOT_NEEDED allowed bare declaration without reason (abuse observed). WORKFLOW_DOCS_NOT_NEEDED allowed skipping docs, contradicting the policy that docs must always be actually updated (complete = actually completed).
Changes: Added WORKFLOW_RESEARCH_NOT_NEEDED and WORKFLOW_PLAN_NOT_NEEDED sentinels with mandatory reason (>=3 non-space chars, not a placeholder, no '>'). Migrated WORKFLOW_WRITE_TESTS_NOT_NEEDED to reason-required form; all three record status: skipped with skip_reason. Removed WORKFLOW_DOCS_NOT_NEEDED — replaced with deprecation message. Updated SKIPPABLE_STEPS (+ write_tests), settings.json ask block, CLAUDE.md workflow steps, workflow-gate.js SKILL_MAP, and skill completion sections (survey-code, deep-research, make-plan, update-docs). Tests: main-workflow-skip-sentinels.sh (18 cases, all PASS), main-workflow-evidence.sh updated (WS-EV-8/8b updated, WS-EV-9-18 deleted).

### SECURITY: Security Enhancement Phase 3: /review-plan-security + /review-code-security + hard-secret detection (2026-04-18, pending)
Background: Phase 3 redesigned /review-security into two companion skills with clear invocation timing: /review-plan-security (Step 2, planning-time checklist) and /review-code-security (Step 5, code-review-time patterns). Original plan used /scan-security but the name implied a different tool type; renamed to reflect when each skill is called. check-private-info.sh lacked coverage of structured API secrets (LLM keys, GitHub tokens, etc.) - only personal information was detected.
Changes: git mv review-security/ -> review-plan-security/: updated frontmatter name/description, added companion reference to /review-code-security. New claude-global/skills/review-code-security/SKILL.md: same 3-axis structure (### Axis 1/2/3), each axis uses italic Axis scope: instead of Source: because patterns derive from Gitleaks/CWE not OWASP directly; Automated coverage note explains hard-secret patterns are handled by check-private-info.sh. bin/check-private-info.sh extended with 11 hard-secret detection patterns: AWS AKIA key, PEM private key header, GitHub PAT, Slack token, OpenAI, Anthropic (checked before OpenAI to prevent sk- prefix overlap), Google, HuggingFace, Groq, Replicate, Cohere. claude-global/hooks/pre-commit extended to block dotenv file commits (allows dotenv.example/.sample/.template). claude-global/CLAUDE.md Step 2 updated to /review-plan-security; Step 5 adds conditional /review-code-security call. 4 new/updated test files: main-review-code-security.sh (renamed from main-scan-security.sh, 20 cases), main-review-plan-security.sh (new, 16 cases, axis consistency test), main-hard-secret-scan.sh (new, 11 normal + edge cases), main-env-file-block.sh (new, pre-commit dotenv block tests). All tests PASS.

### SECURITY: Security Enhancement Phase 4: Trojan Source detection + scan-outbound rename (2026-04-18, pending)
Background: Phase 4 was redesigned from 'add Prompt Injection Defense section' after analysis showed: (1) Prompt Injection patterns fit existing Axis 2/3 rather than needing a new Axis 4; (2) the pre-commit context suits Trojan Source detection (CVE-2021-42574) rather than prompt-injection defense, whose correct defense point is at PostToolUse (tool results entering the LLM); (3) the tool name check-private-info.sh was too narrow for its expanding scope. JudgeClaw (C:/LLM/judgeclaw bridge/injection_signals.py) surveyed as the baseline pattern set for the planned Phase 5 PostToolUse hook.
Changes: Renamed bin/check-private-info.sh to scan-outbound.sh, hooks/check-private-info.js to scan-outbound.js, docs/private-info-scanning.md to scan-outbound.md; updated 20+ references across tests, hooks, settings, and docs. Added zero-width char (U+200B/C/D, U+FEFF) and Bidi override (U+202D/E, U+2066-2069) detection as [zero-width]/[bidi-override] labels in scan-outbound.sh (Trojan Source, CVE-2021-42574). Added Tool Poisoning/Rug Pull/Return Value Injection to review-plan-security and review-code-security Axis 2; Instruction override/Base64 obfuscation added to Axis 3. Source Integrity section added to review-plan-security. Phase 5 (PostToolUse hook) added to plan.md and todo.md for future implementation. Tests: main-hidden-char-scan.sh (18 cases, all PASS); regression: main-hard-secret-scan.sh, main-review-code-security.sh, main-review-plan-security.sh all PASS.

### REFACTOR: workflow-mark: && chaining support + workflow step rename (2026-04-20, (pending))
Background: workflow-mark.js applied strict anchored regex to the full Bash command string. Sentinel echos chained with && in one Bash call (e.g. echo <<A>> && echo <<B>>) never matched, leaving state unrecorded. Additionally, VALID_STEPS contained code/verify but SKILL_MAP had no entries for them -- gate fell back to the generic WORKFLOW_MARK_STEP_* hint and Claude was echoing the sentinel without performing the actual step.
Changes: Refactored workflow-mark.js to split command on &&. All-or-nothing validation: if any part is not a sentinel (e.g. cd /tmp), the whole command is rejected, preserving the existing security property that prefix-chained commands do not update state. Handlers converted from early-exit done() to messages[] accumulation loop. Renamed workflow-state.js steps code->run_tests and verify->review_security; added review_security to SKIPPABLE_STEPS. Added run_tests and review_security entries to workflow-gate.js SKILL_MAP. Added REVIEW_SECURITY_NOT_NEEDED sentinel and handler. Updated CLAUDE.md Step 5 to Run tests and Security review with parallel execution and hook auto-mark. Tests: tests/main-workflow-and-chain.sh added (32 cases, all PASS).

### BUGFIX: Fix workflow-gate: quoted -C path causes hasStagedDocChanges false-negative + fail-open bypass (2026-04-20, 7a25c16)
Background: resolveRepoDir() used \S+ regex to extract git -C <arg>, capturing quoted paths verbatim (e.g. c:/LLM/ai-specs with surrounding quotes). execSync received an invalid cwd, making hasStagedDocChanges/hasStagedTestChanges always return false — gate blocked even when docs/tests were staged. Deeper issue: the same \S+ in commit detection stopped at the first space in a quoted path with spaces, causing !commitMatch to fire and approve() to run — silently bypassing all gate checks (fail-open).
Changes: New claude-global/hooks/lib/parse-git-args.js with parseGitCArg() — quote-aware parser handling bare, double-quoted, and single-quoted -C arguments; unterminated quotes return null. workflow-gate.js: resolveRepoDir delegates to parseGitCArg; commit detection refactored to 2-step check to prevent bypass. is-private-repo.js: extractRepoDirFromCommand delegates to parseGitCArg. resolveRepoDir adds c:/path -> c:\path normalization on win32. Tests: tests/fix-workflow-gate-unix-path.sh extended with Sections D-G (34 cases total, all PASS).

### FEATURE: doc-append: global launcher + category prefix system (2026-04-20, (pending))
Background: doc-append.py was only callable from dotfiles CWD via 'uv run bin/doc-append.py', blocking history.md writes in other repos (ai-specs etc.) where the script doesn't exist. Also lacked a structured classification system for history entries.
Changes: Added --category required arg (INCIDENT/BUGFIX/FEATURE/REFACTOR/CONFIG/SECURITY). Entry format changed to '### CATEGORY: Subject' and '### INCIDENT: #N: Subject'. Install scripts (dotfileslink.sh/ps1) now generate ~/.local/bin/doc-append launcher at setup time. settings.json allow rule updated to 'Bash(doc-append *)'. check-japanese-in-docs.js hook updated to catch wrapper form via regex. Migrated 186 existing history entries across 3 files with heuristic categorization.

### FEATURE: doc-rotate: index.md category badges + distribution summary + --rebuild-index flag (2026-04-20, (pending))
Background: After the category prefix migration (FEATURE/BUGFIX/INCIDENT/etc.), history/index.md still showed entries without category labels — the index was generated before migration and not regenerated since. There was also no way to rebuild the index without running a full rotation, so manual archive edits or schema changes left the index stale.
Changes: doc-rotate.py _write_index now (1) emits a Category Distribution section with per-category counts (e.g. 'FEATURE: 94 | BUGFIX: 25 | ...'), (2) prefixes each entry with a backtick category badge (e.g. `FEATURE`), (3) strips the CATEGORY:/INCIDENT:#N: prefix from displayed link text. Added _extract_category and _subject_from_header helpers and a CATEGORY_PREFIX_RE constant. New rebuild_index(history_path) function reads existing archive files plus current history.md and rewrites only history/index.md without touching the body. New --rebuild-index argparse flag exposes this. docs-convention.md updated with the new tool entry. Tests: 6 new cases in tests/feature-doc-tools.py (test_n4-n9): badge presence, distribution summary, rebuild-index, link text stripping, INCIDENT format, uncategorized entries, idempotency. All 35 tests pass.

### SECURITY: Phase 5: scan-inbound PostToolUse hook for prompt injection defense (2026-04-20, ecb70ff)
Background: No PostToolUse hook existed to detect prompt injection in WebFetch results before they reached the LLM. External content fetched during deep-research was the primary attack surface. JudgeClaw (C:/LLM/judgeclaw) injection_signals.py served as the baseline pattern set. Confirmed during implementation that PostToolUse supports decision:block (prior research was incorrect). Content over 2MB is blocked immediately to prevent timeout-based scan bypass attacks. Discovered a shared-buffer bug in the existing readSync loop pattern used by other hooks; fixed in this hook using fs.readFileSync(0).
Changes: Added claude-global/hooks/scan-inbound.js. BLOCK signals: chatml_tag, direct_override (EN/JP), disregard_jp, expose_system_jp. WARN signals: role_tag, base64_blob (60+ chars with benign-context exclusion for PEM, data URI, data:application/). Content over 2MB triggers content_too_large BLOCK. extractText() recursion depth-limited to 20 to prevent stack overflow on crafted nested payloads. Added PostToolUse WebFetch matcher to settings.json. 31 tests in tests/main-scan-inbound.sh.

### FEATURE: doc-append: auto-rotate when history.md >= 500 lines (2026-04-20, pending)
Background: Manual rotation step required noticing the warning and remembering to run doc-rotate.py. Easy to skip — files grew past the soft limit unattended.
Changes: doc-append.py now invokes doc-rotate.py as a subprocess (--threshold-warn 500 --floor 20) when the resulting file is >= 500 lines. Rotation already calls _write_index, so history/index.md is rebuilt in the same pass. Tests cover trigger, silent under threshold, and that the just-appended entry remains in the body.

### CONFIG: Add WebFetch allow domains for deep-research (2026-04-20, HEAD)
Background: WebFetch permission list only covered specific doc sites. Claude/MCP/LangChain research during deep-research sessions prompted for each new domain.
Changes: Added 8 domains to permissions.allow: code.claude.com, platform.claude.com, anthropic.com, modelcontextprotocol.io, spec.modelcontextprotocol.io, ecc.tools, docs.langchain.com, reference.langchain.com.

### FEATURE: write-tests skill: enumerate call paths step (2026-04-20, (pending))
Background: Incident #21 (CLAUDE_ENV_FILE export prefix bug) revealed that tests only covered single-file units; integration path boundaries were never enumerated as test targets, allowing format mismatches to go undetected.
Changes: Added step 3 'Enumerate call paths' to write-tests SKILL.md Procedure — traces callers -> file -> downstream consumers, identifies format/contract expectations at each boundary, and feeds potential mismatches into step 4 as integration-path error cases. Steps 3-5 renumbered to 4-6.

### FEATURE: workflow-gate: docs-only commit short-circuit (2026-04-21, pending)
Background: After VS Code restarts, new Claude Code sessions required 4-5 ask-dialog clicks (WORKFLOW_*_NOT_NEEDED: echoes) to commit a trivial follow-up change such as ticking a checkbox in docs/todo.md. The workflow gate guards code quality — these checks were unnecessary overhead for docs-only changes.
Changes: Added isDocsOnlyStaged(repoDir) to workflow-gate.js. When all staged files match docs/*.md, all steps except user_verification are automatically bypassed. Block message replaced with 'docs-only commit — only user_verification is required.' Files outside docs/ (CLAUDE.md, SKILL.md, root README.md, etc.) are treated as behavior code and excluded. Tests: tests/feature-workflow-gate-docs-only.sh (18 cases, all PASS). Documentation added to CLAUDE.md and docs/architecture/claude-code.md.

### FEATURE: Consolidate Workflow State Machine tests into single integration file (2026-04-21, TBD)
Background: Workflow State Machine tests had accumulated as separate files per feature addition — 7+ files coexisted with no CI runner, making it unclear which files to run for sufficient regression protection. The todo.md task to automate manual E2E verification scenarios triggered a consolidation refactor.
Changes: New: tests/main-workflow-state-machine.sh (38 cases, Sections 1-6) covering state inheritance, cross-repo commit, RESET_FROM, USER_VERIFIED, branch isolation, and security injection as integrated regression tests. Deleted: feature-robust-workflow-user-verified.sh, feature-robust-workflow-session-start.sh, feature-robust-workflow-integration.sh, feature-workflow-gate-docs-only.sh, feature-workflow-post-compact.sh. Shrunk: feature-robust-workflow-settings.sh reduced to structural smoke tests SR1-SR5 only. Mutation probe (6 mutations, S1-S6) confirmed the aggregated test catches real bugs in each section.

### FEATURE: block-tests-direct.js: enforce test writes via /write-tests hook (2026-04-21, pending)
Background: Claude probabilistically violated the test.md rule 'Do not write or edit test files directly in the main conversation', prompting the user for Write/Edit approval each time. A mechanical enforcement via PreToolUse hook was needed.
Changes: Added block-tests-direct.js hook: denies Write/Edit/MultiEdit targeting a tests/ path when the workflow write_tests step is pending and agent_id is absent (main conversation). agent_id reliably distinguishes main from subagent — verified empirically on Claude Code sonnet-4-6 (agent_id absent in main, populated in subagent). Added Write|Edit|MultiEdit PreToolUse matcher to settings.json. Directory name configurable via CLAUDE_BLOCK_TESTS_DIR_NAMES env var (default: tests). Fail-open on any error path.

### FEATURE: workflow-gate: extend docs-only short-circuit to root human-facing .md files (2026-04-22, pending)
Background: The 2026-04-21 short-circuit design treated root README.md as behavior code (excluded from docs-only bypass). In practice README.md is human-facing documentation (per rules/docs-convention.md: 'External-facing overview', 'Compact'), and standalone README catchup commits (e.g. d4b0f55) required navigating the full 6-step workflow gate — unnecessary overhead for non-code changes. User confirmed that root-level human-facing .md files (README/CHANGELOG/CONTRIBUTING/LICENSE) warrant the same short-circuit treatment as docs/*.md, while CLAUDE.md/SKILL.md remain behavior/prompt code.
Changes: workflow-gate.js: replaced the isDocsOnlyStaged predicate from startsWith('docs/') && endsWith('.md') to a named constant DOCS_ONLY_ALLOWLIST = /^(docs\/.+\.md|(README|CHANGELOG|CONTRIBUTING|LICENSE)\.md)$/i. Subdirectory README.md and CLAUDE.md remain excluded. claude-global/CLAUDE.md, docs/architecture/claude-code.md (x2), and README.md updated to reflect new allowlist semantics. Tests: added L2-c2..c5 to main-workflow-state-machine.sh (root README.md → short-circuit, docs+README mix → short-circuit, root CLAUDE.md → full gate, subdir README.md → full gate).

### FEATURE: update-docs skill: structure README.md into routine (step 2/3/Completion) (2026-04-22, pending)
Background: update-docs/SKILL.md listed README.md as a target in the header (line 11) but step 2 (Read current docs), step 3 (Identify gaps), and the Completion git add command did not reinforce it. In practice the README was read-passed only when Claude remembered to, leading to standalone catchup commits like d4b0f55. The skill also lacked a clear statement of what a README should achieve.
Changes: step 2: added explicit note to always include root README.md in the read pass. step 3: added README.md goal ('make the reader think I want to use this — key features in crisp abstract terms') and update trigger criteria. Completion: git add changed from 'git add docs/' to 'git add docs/ README.md' with a note to omit the path when no README exists.

### FEATURE: docs/history.md classification -- history-classification.md + split-history.py (2026-04-25, pending)

Background: Step 6 of the agents repo split. Classified all 71 history.md entries into @claude (agents repo), @dotfiles (keep in dotfiles repo), or @both, then built a machine-driven split script to produce the two output files.

Changes: Created docs/history-classification.md (71 entries: @claude=58, @dotfiles=13, @both=0). Created bin/split-history.py: reads history.md + classification table, writes history-agents.md (@claude+@both) and history-dotfiles.md (@dotfiles+@both). Normalization: strips trailing date suffix like (2026-04-12, abc1234); normalizes INCIDENT: #N: -> INCIDENT #N: for fuzzy match. 0 unmatched entries on current history.md. Added 11 tests (N11-N15, E4-E6, I1, ER1-ER2) to tests/feature-agents-repo-split.sh.

### FEATURE: agents-split step 2: introduce AGENTS_CONFIG_DIR abstraction (2026-04-25, ca3ceec)

Background: settings.json had 11 hardcoded $DOTFILES_DIR/claude-global/hooks/*.js paths. To enable the agents repo split, these needed to be abstracted behind a $AGENTS_CONFIG_DIR env var so the same settings.json works whether the hooks live in dotfiles or a standalone agents repo.

Changes: Updated settings.json 11 hook paths from $DOTFILES_DIR/claude-global/hooks/* to $AGENTS_CONFIG_DIR/hooks/*. Added $AGENTS_CONFIG_DIR and $AGENTS_DIR (with BEGIN/END temporary compat defaults pointing to claude-global) to .profile_common and install/win/profile.ps1.

### FEATURE: agents-split step 3: abstract hook scanner path via AGENTS_CONFIG_DIR (2026-04-25, e79cb06)

Background: pre-commit and commit-msg hooks used relative paths (../../bin/scan-outbound.sh), which would break when the hook directory moves to the agents repo. scan-outbound.sh used a hardcoded dotfiles-private sibling path that would not exist in a standalone agents install.

Changes: Updated pre-commit and commit-msg hooks to use $AGENTS_CONFIG_DIR/../bin/scan-outbound.sh. Updated scan-outbound.sh sibling path to use ${DOTFILES_PRIVATE_DIR:-$DOTFILES_DIR/../dotfiles-private} optional fallback — warns and continues with empty allowlist if unset.

### FEATURE: agents-split step 4: abstract session-sync path via AGENTS_DIR (2026-04-25, 08bd2c4)

Background: .profile_common referenced $DOTFILES_DIR/bin/session-sync.sh directly. After the split, session-sync.sh will live in the agents repo bin/, so the path needed to be driven by $AGENTS_DIR.

Changes: Updated .profile_common session-sync calls to use ${AGENTS_DIR}/bin/session-sync.sh.

### FEATURE: agents-split step 5: classify 76 tests for repo split (tests/split-plan.md) (2026-04-25, dd61833)

Background: 76 test files in tests/ cover both dotfiles-specific and claude-framework-specific functionality. A classification table was needed before the split to ensure each test lands in the right repo.

Changes: Created tests/split-plan.md with a per-file classification table (@claude/@dotfiles/@both) covering all 76 test files. Rationale is recorded for ambiguous entries.

