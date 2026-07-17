# History (agents)

## Archived
- [2026](1784244559-505473-pr1475-history-staging/2026.md) — 93 entries

### BUGFIX: PR #1417 — fix/fix-882 (2026-07-13, c429926, #1417)

Background: fix(#882): extract session-bound worktree resolution into SSOT helper; wire RT-1/RT-4a to it

Changes: Extracted session-bound worktree resolution into `hooks/lib/workflow-state/resolve-worktree-path.js`: `isMainWorktree(dir)` (fail-close, execFileSync argv form) and `resolveSessionWorktreePath()` (fail-safe, reads state.cwd, rejects main worktree).;Added `bin/resolve-worktree-path` CLI wrapper: no-sid→empty, no-state→"NOSTATE", linked-wt→path, main/error→empty.;Added `skills/review-tests/scripts/select-staged-files.sh`: WORKTREE path→`git -C $WORKTREE diff --cached`; NOSTATE→cwd fallback; empty→exit 3.;Wired SKILL.md RT-0/RT-1/RT-4a to the SSOT: RT-0 resolves WORKTREE via CLI; RT-1 delegates file selection to select-staged-files.sh; RT-4a passes `${WORKTREE:-}` as argv[2] to compute-staged-tests-token.js.;Removed duplicate `isMainWorktree()` and execSync from `bin/compute-staged-tests-token.js`; wired to SSOT resolver. <!-- compose-doc-append-sentinel: branch=fix/fix-882 pr=#1417 -->

Test gap: no L2 test for RT-1 staged-file selection via session state before this fix

### BUGFIX: PR #1418 — fix/fix-1415 (2026-07-13, e2f3f783b48c366dc2211a27ac4d81ca648e71f4, #1418)

Background: PR #1418 merged on 2026-07-13.

Changes: fix(#1415): add record_type enum field to supervisor findings; supervisor-off-proposal-shim excludes escape_hatch_event from blockingFindings, resolving cycle where WORKTREE_OFF/WORKFLOW_OFF sentinel audit records blocked subsequent OFF sentinel emits in the same session <!-- compose-doc-append-sentinel: branch=fix/fix-1415 pr=#1418 -->

### FEATURE: PR #1420 — feature/canary5-6git (2026-07-13, 79547ed278cb7d8836b8db76c85a602af628fa12, #1420)

Background: feat(#1400,#1401): WRITE_PATTERNS→IR migration — retire green-group + git, typed write-target contract, fail-closed security convergence

Changes: FEATURE #1400: canary-5 — retire 12 "green-group" WRITE_PATTERNS surface-regex entries (posix-redir ×2, pwsh ×7, file-op rm/cp/mv ×3) from `hooks/lib/bash-write-patterns/patterns.js` and `STRIP_KINDS`. Write-detection for these groups is now performed exclusively by the IR-based predicates `isPosixRedirWriteIR`, `isPwshWriteIR`, and `isFileOpWriteIR` in `bash-write-targets.js`. Added typed write-target contract `{resolveVia:"ancestor"|"self", path}` at the `collectWriteTargetsFromSegments` collector layer; all downstream consumers (`bash-write-scope.js`, block hooks) updated to use `.path`. Migrate sibling test suites (feature-parallel-sessions-worktree-bash-patterns, fix-1391, fix-416, refactor-1294, fix-876, fix-fd-redirect) to assert new `classify()=="read"` + IR predicate contract.;FEATURE #1401: canary-6-git — retire 18 git WRITE_PATTERNS surface-regex entries. Introduce `isGitWriteIR` (read-allowlist + unknown→write fail-closed, basename-aware for /usr/bin/git/git.exe) in new `hooks/lib/bash-write-patterns/git-write-ir.js`. Add `extractGitWriteTargets` in `hooks/lib/bash-write-targets/git.js` returning `{resolveVia:"self", path:repoRoot}` self-target. Redesign `findRepoRootForBash` to resolve scope per write-segment's own IR argv (segment-aware, quote-aware; cross-segment/quoted --work-tree mis-scope → fail-closed to in-session). Add `resolveGitSubArgv` (skips git global flags via parse-git-args.js SSOT). Add `peelWrappers`/`scanWrappedVerb` with basename lookup so `/usr/bin/env git commit`, `/usr/bin/nice git commit` are caught. Add `isEverySegmentExcluded` git/gh per-segment write predicate (prevents `cp … && git commit` allow bypass). Add `isCommandSubstWriteIR` (writes in `$(…)`/backtick), `isNewlineInjectedWriteIR` (newline-injected writes), `isExoticExecWriteIR` (eval/xargs/find-exec/process-subst/sh-c/pwsh-Command). All exotic predicates wired into fast-allow gate, `isEverySegmentExcluded`, and `isReadOnlyInterpreterC`. Security: all fail-closed (unknown subcommand→write, ambiguous scope→in-session block, dynamic eval body→write). Canary suite 326 cases green. <!-- compose-doc-append-sentinel: branch=feature/canary5-6git pr=#1420 -->

### FEATURE: PR #1429 — fix/fix-supervisor-1342-1381-1374 (2026-07-13, 5f02c2f, #1429)

Background: PR #1429 merged on 2026-07-13.

Changes: BUGFIX #1342: SC-6 Final Report `findingsRender` call used `forFinalReport: true` (full per-finding detail dump); changed to `summaryOnly: true` to emit a count+severity summary line only, suppressing the verbose dump in session-close output.;BUGFIX #1381: SC-6 did not clear `audit_phase` / `audit_armed_at` after Final Report; added `--clear-audit-phase` flag to `bin/supervisor-write-audit` and wired it into the SC-6 completion block so audit state is reset on session close, eliminating the infinite audit re-arm loop that fired after every Final Report.;BUGFIX #1374: `checkSupervisorPreMerge()` blocked on any non-null `audit_verdict` including stale WARN verdicts (regression from PR #1360); fixed to skip the warning-flush block when a fresh non-BLOCK audit verdict exists (isAuditVerdictFresh: audit_last_run_at >= newest finding timestamp); only BLOCK verdict always gates; stale WARNs and fresh WARN/CONTINUE verdicts no longer block merges. Test gap: no test asserted that a WARN verdict with a timestamp older than the newest finding bypasses the pre-merge gate. <!-- compose-doc-append-sentinel: branch=fix/fix-supervisor-1342-1381-1374 pr=#1429 -->

### FEATURE: PR #1430 — feature/1145-we15-adaptive (2026-07-13, d278f895c2a858bb62c45c5679779b3112668658, #1430)

Background: feat(#1145,#1404): WE-15 adaptive block message + cleanup-cascade/SKILL.md guardrails

Changes: FEATURE #1145 #1404: Added adaptive OFF-block message in `supervisor-off-proposal-shim.js` that detects worktree-end phase via `isWorktreeEndEnv()` (new `hooks/lib/worktree-end-env-anchor.js`) and surfaces `/sweep-worktrees` + WE-16 fallback guidance instead of generic text. Strengthened `cleanup-cascade.md` WE-15/WE-16 and `SKILL.md` with explicit prohibition of `WORKTREE_OFF` and `--force`, and sweep-auto-reclaim guidance. <!-- compose-doc-append-sentinel: branch=feature/1145-we15-adaptive pr=#1430 -->

### FEATURE: PR #1433 — feature/test-design-split-1431 (2026-07-13, 251243173b74c74fa70e249cf35e84df805e4a28, #1433)

Background: feat(#1431): test-design.md progressive-disclosure split + Pattern 4 classifier coverage

Changes: feat(#1431): progressive-disclosure split of `skills/_shared/test-design.md` (288L → 180L entrypoint + `test-design/parser-regex-tests.md` + `test-design/protection-fix-tests.md`); added Classifier/guard cases Pattern 4 bullet to Test Case Categories (CPR-5 both-direction coverage, origin: #1425); updated `write-tests` WT-1 and `review-tests` RT-0a to read `rules/core-principles.md` first; wired `review-tests/scripts/run-codex-review-loop.sh` and `agents/test-reviewer.md` to load detail files conditionally; updated test comment pointers in feature-1308 and feature-1340 test helpers <!-- compose-doc-append-sentinel: branch=feature/test-design-split-1431 pr=#1433 -->

### FEATURE: PR #1434 — docs/issue-1428 (2026-07-13, 4fc6a17, #1434)

Background: feat(#1428): rename review-skill-size → review-prompt-size; extend to rules/*.md, agents/*.md, skills/_shared/*.md

Changes: Renamed `bin/review-skill-size` → `bin/review-prompt-size` and extended diff-mode and `--all` scan to cover `rules/*.md`, `agents/*.md`, and `skills/_shared/*.md` in addition to `SKILL.md`. Updated `rules/coding/file-split.md` Pattern B and `rules/prompt.md` scope definition. Updated all references in `README.md`, installer scripts, and `run-quality-gates.sh`. Closes #1428. <!-- compose-doc-append-sentinel: branch=docs/issue-1428 pr=#1434 -->

### FEATURE: PR #1437 — fix/1435-precommit-env (2026-07-14, 12bea8c, #1437)

Background: fix(#1435): block modified .env files in pre-commit (--diff-filter=AM)

Changes: BUGFIX: pre-commit `--diff-filter=A` → `AM` — block modified .env files at commit time (#1435). Test gap: no test verified that modifying an existing tracked .env was blocked; Test 7 expected rc=0 (gap). Added Test 7 rc=1 and Test 8 (gh api failure → treat as public). <!-- compose-doc-append-sentinel: branch=fix/1435-precommit-env pr=#1437 -->

### FEATURE: PR #1438 — fix/1436-fd-dup (2026-07-14, b7c4f91416c105fd1ccfd23a4f02105222c1f948, #1438)

Background: fix(#1436): exclude FD-to-FD redirects from isPosixRedirWriteIR write detection

Changes: Added `&& !/^&\d/.test(r.targetRaw)` to `writeRedirs` filter in `isPosixRedirWriteIR` (bash-write-targets.js:93) to exclude FD-to-FD redirects (`2>&1`, `>&2`) from write-target detection. Root cause: PR #1420 (2026-07-12) retired surface-regex entries with FD-to-FD negative-lookahead (from BUGFIX #243, PR #304) without porting the guard to `isPosixRedirWriteIR`. Four regression rows added to commit2-green-retire.sh POSIX_TABLE: PR-BUG-FD2/FD3 (Red→Green) and PR-BUG-FDQ/FDQ2 (always-true guard against `r.target`-based regression). Test gap: no `isPosixRedirWriteIR` regression test for FD-to-FD redirects (`2>&1`) as a non-write case. <!-- compose-doc-append-sentinel: branch=fix/1436-fd-dup pr=#1438 -->

### FEATURE: PR #1439 — fix/meta-filter-complexity-1427 (2026-07-14, f6c9163, #1439)

Background: fix(workflow-init): meta-label exclusion, Path A complexity recording, record-complexity-and-skip

Changes: BUGFIX #1427/#1394/#1413: Added meta-label exclusion axis to filter-primary-candidates.sh (extended Pass A to --json parent,labels; Pass B now drops meta candidates when at least one non-meta candidate survives). Added complexity evaluation + outline skip substeps to workflow-init Path A. Extracted the 3-step node sequence from clarify-intent CI-C1b/C1c into shared script bin/workflow/record-complexity-and-skip; rewrote both SKILL.md callers as thin wrappers. Fixed shell-variable interpolation into node -e double-quoted body (CWE-78): switched to process.env pattern. Split tests/feature-1351-skip-conditions-from-complexity.sh into _lib.sh + behavioral.sh to resolve HARD line-limit violation. Test gap: FP-10/FP-11/FP-12 tests for the meta-label exclusion axis were absent before this fix <!-- compose-doc-append-sentinel: branch=fix/meta-filter-complexity-1427 pr=#1439 -->

### FEATURE: PR #1451 — fix/1443-1442-worktree-context (2026-07-17, 9af4f07855de1502288e7e04aa2e776790830145, #1451)

Background: fix(#1443,#1442): WE-7/WE-8 linked-worktree CWD directives + CWD-independent session-ID fallback

Changes: #1443: WE-7/WE-8 in worktree-end SKILL.md now direct the model to keep CWD in the linked worktree until WE-13 (step text + Rules bullet, CPR-5 symmetric). New single-responsibility PostToolUse hook `hooks/detect-worktree-conflict.js` (registered in settings.json, matcher `Bash|runInTerminal|runCommands`) emits one non-blocking `additionalContext` guidance message when a failed command's stderr matches `fatal: '<branch>' is already used by worktree`. Deliberately one pattern + one message; generalization deferred to #1447. Test gap: no test asserted WE-7/WE-8 CWD directives or any guidance path for worktree-conflict git errors.;#1442: session-ID resolution no longer depends on CWD. Both `resolveWorkflowSessionId()` (new Priority 1d) and `resolveSessionId()` (new Priority 6c) gained a symmetric sibling-worktree scan that reads WORKTREE_NOTES.md Session-ID from linked worktrees after all env-var priorities fail: own worktree (CWD or ancestor) wins, a single sibling resolves, multiple distinct sibling IDs return null (fail-safe, no fall-through to depth-score/JSONL scans). Codex security review found and this session fixed a HIGH own-worktree false-ambiguity bug (subdirectory CWD collected own root as a sibling) via fail-before-fix tests. Test gap: no test called either resolver from a main-worktree or subdirectory CWD with session env vars absent. <!-- compose-doc-append-sentinel: branch=fix/1443-1442-worktree-context pr=#1451 -->

### FEATURE: PR #1458 — feature/workflow-init-driver (2026-07-17, cc0a35bea927848ba09fb97d0ce02be29cdadf92, #1458)

Background: feat(workflow-init): consolidate WI-2..WI-9 into resumable Node.js driver

Changes: #1446: Consolidated workflow-init's mechanical steps WI-2..WI-9 (issue-token detection, per-N `gh issue view` fetch, aggregate WIP check, CLOSED detection, label extraction, route decision, context.md write) into a resumable Node.js state-machine driver `bin/workflow/workflow-init-driver` + `bin/workflow/lib/workflow-init/` (7 phase modules, checkpoint.js, directive.js, spawn-env.js) emitting next-step-style `ACTION=` directives (invoke/done/blocked/ask_user/emit_sentinel) with checkpoint `--resume` support; SKILL.md rewritten as a driver loop (120→92 lines). Background: ds4-model sessions deviated from prose-step interpretation (WI-3 ambiguity, wrong ENFORCE_WORKTREE-block recovery). Includes the aggregate-WIP ALL_NONE unreachable-branch fix (evaluation order now error → any_other → all_none → all_same → mixed) and three security-review fixes (sentinel stripping restored in context.md write, CWE-77; CLAUDE_SESSION_ID validated against `/^[A-Za-z0-9_-]+$/` before path use, CWE-22; OPTIONS_DISPLAY percent-encoded symmetrically with QUESTION). Retired 4 scripts (aggregate-wip-check.sh, wip-set-resume.sh, closed-detection.sh, list-open-sub-issues.sh); new tests/feature-workflow-init-driver/ (103 assertions) + top-level dispatcher.;#795: Abolished the remaining "primary issue" concept — `filter-primary-candidates.sh` renamed to `filter-init-candidates.sh`; `path-a-label-and-board.sh` internal names PRIMARY/RELATED renamed to FIRST_N/SIBLINGS; all closes_issues entries are processed symmetrically in the driver's route decision.;#996: Removed all WORKFLOW_ABORTED_* sentinels (6 occurrences across workflow-init and clarify-intent SKILL.md) — audit found no consumer; abort paths now surface as driver `ACTION=blocked` or a plain stop. <!-- compose-doc-append-sentinel: branch=feature/workflow-init-driver pr=#1458 -->

### FEATURE: PR #1459 — fix/enforce-worktree-ir-regression (2026-07-17, ff050931, #1459)

Background: fix(enforce-worktree): restore scratchpad-redirect and New-Item-Directory allow paths lost in PR #1420 IR-signature migration

Changes: #1109: Investigated the 8 reported main-worktree false-blocks attributed to PR #1420's `collectBashWriteTargets` IR-signature migration (`(cmd)` → `(ir, repoRoot)`). The plans-dir heredoc / `node -e` writes were already green (PR #1179); the residual scratchpad-redirect variants were the regression. Fixed by teaching `expandStaticShellTokens` to expand `$SCRATCHPAD`/`${SCRATCHPAD}` only when they resolve under `<os-tmpdir>/claude/`, and adding the `areAllBashTargetsUnderClaude` allow predicate (fail-closed: allowed only when ALL targets resolve under the session scratchpad, tightened to `$SCRATCHPAD` when set). New SSOT `hooks/lib/claude-scratchpad-base.js` guards against TEMP/TMP poisoning by excluding paths that resolve inside the repo.;#1441: Restored the `New-Item -ItemType Directory` allow path that PR #1420 dropped when pwsh WRITE_PATTERNS were retired (on Windows, `findRepoRoot` on a non-existent external path fell back to process CWD → main repo root → block). Extracted the logic into `hooks/enforce-worktree/main-worktree-allows/new-item.js` with head-anchored dispatch, argv0 verification, and PowerShell single-quote literal semantics (`'$SCRATCHPAD/x'` stays literal → in-repo → block). The supervisor scratchpad stdout-redirect gap is covered by the same `areAllBashTargetsUnderClaude` predicate.;#1290: Same New-Item root cause as #1441 — `New-Item -ItemType Directory` issued during `/worktree-start` WS-5 (sanctioned parent-dir creation) is allowed again through the restored branch. Kept fail-closed for `-ItemType File`, in-repo targets, and chained commands.;#923: Confirmed `git worktree remove` (and add/prune) from the main worktree is allowed after restructuring `isAllowedWorktreeCommand` into a head-first dispatch (git-worktree vs New-Item) and splitting the 600-line module to satisfy the 500-line HARD limit (`worktree-command.js`, `worker-script.js`, `new-item.js`). Added a permanent regression canary (`tests/fix-1441-new-item-scratchpad-allow.sh`) so the restored allows cannot silently regress again. <!-- compose-doc-append-sentinel: branch=fix/enforce-worktree-ir-regression pr=#1459 -->

### FEATURE: PR #1460 — feature/labels-ssot-propagation (2026-07-17, 8a9364a72c66a279eba3841f5a7abe7d4066d29a, #1460)

Background: feat(#1261): labels.yml SSOT propagation to sibling repos via CI

Changes: FEATURE #1261: labels.yml SSOT propagation to sibling repos — new `bin/github-issues/propagate-labels.sh` (PAT-gated, independent-sibling loop, security: SIBLING regex validation, path-traversal guard on CANONICAL_LABELS_FILE, remote-URL PAT strip after clone, GIT_WORK_DIR cleanup trap); `propagate` job added to `.github/workflows/sync-labels.yml` with `needs: sync` and job-env `HAS_PAT` boolean gate (PAT not in job-level `if:`); `docs/ops.md` PAT creation / repo-scope / first-run runbook; test suite 13 cases (L2 mock git/gh). <!-- compose-doc-append-sentinel: branch=feature/labels-ssot-propagation pr=#1460 -->

### FEATURE: Supervisor alert actionable-only output (#1450, PR #1461) (2026-07-17, 7907234)

Background: EM Supervisor alert mode injected all findings including notice-severity into the main agent context window on every review, causing unnecessary context window pollution with non-actionable information. Approach D selected: Stop hook renders actionable summary deterministically from the state file, making subagent prose output irrelevant to the main context.

Changes: Added actionableOnly mode to formatLayer2Findings (severity>=warning filter, /issue-create hint for actionable categories). Wired actionableOnly:true in stop-l2-findings-display.js (Stop hook hard guarantee). Constrained supervisor.md Reporting back section to fixed one-line ack. Added bin/supervisor-render-alert CLI for manual debugging. Security: applied escapeTokens+newline-collapse in actionableOnly branch (sibling parity with forFinalReport); added SESSION_ID_RE validation to CLI.

### FEATURE: PR #1471 — feature/1255-supervisor (2026-07-17, 6afb230, #1471)

Background: fix(#1255): supervisor reportBlock severity notice + block finding class dedup

Changes: fix(#1255): supervisor `reportBlock()` severity changed "error" → "notice" so hook blocks alone do not arm alert mode (notice short-circuit in `ensureAlertScheduled`); `appendFinding()` extended with session-wide class dedup (reporter + command key) that collapses repeated block findings from the same hook into a `class_dedup_count` field, reducing state file churn <!-- compose-doc-append-sentinel: branch=feature/1255-supervisor pr=#1471 -->

### FEATURE: PR #1472 — feature/canary-6a (2026-07-17, 15da2e27404d616a9cfce45594ecdb3398abefe4, #1472)

Background: feat(#1411): pkg-mgr × 7 + interpreter-c IR migration + retire (canary-6a Phase 2)

Changes: FEATURE #1411 (canary-6a Phase 2): Retired 8 surface-regex WRITE_PATTERNS entries — npm-write, pnpm-write, yarn-write, pip-write, uv-write, cargo-write, go-write, interpreter-c — replacing them with IR-based predicates isPkgMgrWriteIR and isInterpreterCWriteIR. New hooks/lib/bash-write-targets/pkg-mgr.js: read-allowlist fail-closed classifier (npm/pnpm/yarn/pip/pip3/uv/cargo/go) with extractPkgMgrWriteTargets ({resolveVia:"self"} self-target). bash-write-targets.js extended with isInterpreterCWriteIR + hasCFlag helper (case-insensitive PowerShell flags, combined POSIX flags like -lc). Both predicates wired into fast-allow gate (enforce-worktree.js), isEverySegmentExcluded + collectBashWriteTargets (bash-write-scope.js), innerSegIsWrite (classify.js). Security review found and fixed 4 bugs: (1) HIGH — isInterpreterCWriteIR early-return false-allow on multi-segment commands (bash -c 'read-only'; sh -c 'rm f'); (2) pwsh -command (lowercase) not recognized as -c flag; (3) bash -lc (combined POSIX flag) not recognized; (4) npm ci false-positive from ci-alias pwsh-alias pattern — fixed by suppressedPatterns in classify.js. <!-- compose-doc-append-sentinel: branch=feature/canary-6a pr=#1472 -->

### FEATURE: PR #1473 — refactor/scriptify-mop-skill-1464 (2026-07-17, 0325115, #1473)

Background: refactor(#1464): extract inline node -e from make-outline-plan/SKILL.md into scripts

Changes: REFACTOR #1464: Extract inline `node -e` calls from `skills/make-outline-plan/SKILL.md` (MOP-1d, MOP-C1) into `skills/make-outline-plan/scripts/check-outline-skip.sh` and `check-detail-skip.sh`; update tests that grep those patterns <!-- compose-doc-append-sentinel: branch=refactor/scriptify-mop-skill-1464 pr=#1473 -->

### FEATURE: PR #1474 — chore/1467-write-tests (2026-07-17, a94bcb2a360e85f60921bfe343bf7cbed7201220, #1474)

Background: refactor(#1467): scriptify issue-create Phase 4-5 dispatch

Changes: REFACTOR #1467: scriptify issue-create Phase 4-5 dispatch — extracted Phase 4 bulk-sub-of TSV manifest write + dispatch call and Phase 5 worktree-notes-append loop from skills/issue-create/SKILL.md (175 lines, WARN >100) into skills/issue-create/scripts/run-bulk-dispatch.sh and skills/issue-create/scripts/run-phase5-record.sh; SKILL.md Phase 4/5 sections replaced with single-line script invocation directives, resolving rules/prompt.md §1.3 violation <!-- compose-doc-append-sentinel: branch=chore/1467-write-tests pr=#1474 -->

### FEATURE: PR #1475 — feature/1465-scriptify-clarify-intent (2026-07-17, b027a0d6116d4bca70c8f36a7d0cf690bd4dc31a, #1475)

Background: feat(#1465): scriptify clarify-intent/SKILL.md completion and outline-skip dispatch

Changes: FEATURE: scriptify clarify-intent/SKILL.md completion and outline-skip dispatch (#1465) — Background: rules/prompt.md §1.3 requires inline 3+ step procedures to move to CLI; SKILL.md was at 160 lines (WARN exceeded). Two multi-step completion procedures remained inline. Changes: added `skills/clarify-intent/scripts/run-completion.sh` (orchestrates NON_GITHUB gate, closes_issues parsing via parse-closes-issues.js, clarify-commit-scope.sh + clarify-guard-loop.sh; returns single stdout token PROCEED|CREATED:N|CLOSED:N|RC2|NEED_ISSUE|RETRY_EXHAUSTED|CLOSED_ENTRY); added `skills/clarify-intent/scripts/check-complexity-skip.sh` (SKIP_MODE=auto/judgment dispatch, record-skip-judgment call, sentinel echo + SENTINEL_EMITTED/NO_SENTINEL protocol). SKILL.md Completion section and CI-C1c now delegate to these scripts; file reduced from 160 to 135 lines. <!-- compose-doc-append-sentinel: branch=feature/1465-scriptify-clarify-intent pr=#1475 -->

### FEATURE: PR #1476 — feature/1466-detect-non-github (2026-07-17, 5b0e771, #1476)
Background: refactor(#1466): extract NON_GITHUB detection into shared bin/detect-non-github.sh
Changes: refactor(#1466): extract NON_GITHUB detection into shared bin/detect-non-github.sh. Background: Both commit-push/SKILL.md and issue-close-stage/SKILL.md contained a verbatim ~10-line inline bash case block for NON_GITHUB detection (from PR #373, 2026-05-18); the duplicate violated CPR-2 (SSOT). Changes: Created bin/detect-non-github.sh, a shared wrapper around bin/is-github-dotcom-remote that emits the context-specific skip message to stdout and normalizes the 3-value exit-code contract (0=GitHub or fail-open, 1=non-GitHub). Replaced the inline blocks in both SKILL.md files with a single-line invocation. Updated non-github-remote-gate.md to document the Shared detection wrapper tier and annotate each consumer. <!-- compose-doc-append-sentinel: branch=feature/1466-detect-non-github pr=#1476 -->

### FEATURE: PR #1477 — feature/issue-1470 (2026-07-17, 60572a88bba2c2b3b37fa85e03ec99806a53dc9a, #1477)
Background: feat(#1470): add check-inline-procedures quality gate to WF-CODE-6
Changes: Add `bin/check-inline-procedures` quality gate to WF-CODE-6: detects inline numbered procedure blocks (≥3 consecutive `N. ` lines at column 0) in `skills/*/SKILL.md`, `agents/*.md`, and `skills/_shared/*.md`; emits advisory WARN findings. Integrated into `run-quality-gates.sh` alongside `review-prompt-size`. Always exits 0. Closes #1470. <!-- compose-doc-append-sentinel: branch=feature/issue-1470 pr=#1477 -->

### FEATURE: PR #1478 — feature/1468-scriptify-survey-history (2026-07-17, 3913c52, #1478)
Background: feat(#1468): scriptify survey-history/SKILL.md — extract 4 inline violations to scripts
Changes: #1468: scriptify survey-history/SKILL.md — extracted 4 rules/prompt.md §1.3/§1.5 violations to scripts/; reduces SKILL.md from 132 lines to 88 lines (WARN resolved) <!-- compose-doc-append-sentinel: branch=feature/1468-scriptify-survey-history pr=#1478 -->

### FEATURE: PR #1479 — refactor/scriptify-agent-files-1469 (2026-07-17, 4ed0aa4d287b4337224d42448dbc555f9a79489a, #1479)
Background: refactor(#1469): scriptify 5 agent .md files — extract inline procedures to sibling dirs
Changes: Extracted inline procedure blocks from 5 agent .md files to sibling directories (agents/<name>/); created agents/lib/planner-review-loop-protocol.md for the shared Risk-Signal File protocol (outline/detail planners); new sibling files: agents/outline-planner/output-format.md, agents/detail-planner/procedure.md, agents/detail-planner/supplementary-rules.md, agents/issue-close-finalize-worker/state-schema.md, agents/outline-reviewer/concern-identifiers.md, agents/detail-reviewer/concern-identifiers.md; line counts reduced from 108–173 to 76–111; contract sections (Verdict Format, Required response trailer, Output contract, Procedure verdict) kept inline per CPR-6 orchestrator integrity requirement. <!-- compose-doc-append-sentinel: branch=refactor/scriptify-agent-files-1469 pr=#1479 -->

### FEATURE: PR #1481 — feature/canary-7 (2026-07-17, c842367, #1481)
Background: feat(#1402,#1296): canary-7 pwsh-alias/pwsh-encoded/here/file-op IR retire + canary-final
Changes: FEATURE #1402: canary-7 — Retired 23 surface-regex WRITE_PATTERNS entries (pwsh-alias: sc/ac/ni/ri/mi/ci × 6; pwsh-encoded: encoded-command/ps-stop-parsing × 2; here-doc/here-string × 4; file-op: sed-inplace/perl-inplace/patch/touch/chmod/dd/rsync/tar-extract/unzip/gunzip/bunzip2 × 11) into IR predicates. New modules: hooks/lib/bash-write-targets/here.js (isHereWriteIR), encoded.js (isEncodedCommandWriteIR), file-op.js (isExtendedFileOpWriteIR + extractFileOpTargets). All three wired into fast-allow gate (enforce-worktree.js), isEverySegmentExcluded + collectBashWriteTargets (bash-write-scope.js), and innerSegIsWrite (classify.js C4). isPwshWriteIR extended with mi/ci. WRITE_PATTERNS reduced to 4 here-doc entries; STRIP_KINDS emptied. classify() returns "read" for retired verbs (IR predicates handle detection at hook level).;FEATURE #1296: canary-final — AT-DP2 bridge condition removed (WRITE_PATTERNS no longer drives the block decision for retired entries); block-extras.js inlined into enforce-worktree.js; Phase 2 WRITE_PATTERNS retirement complete. <!-- compose-doc-append-sentinel: branch=feature/canary-7 pr=#1481 -->

### FEATURE: PR #1480 — feature/scriptify-session-close (2026-07-17, cd9cb305c9fd1da801cdec7434cf33d7382f22d9, #1480)
Background: refactor(#1463): scriptify session-close/SKILL.md
Changes: REFACTOR #1463: scriptify session-close/SKILL.md — extracted SC-1a WF-META detection (`bin/session-close-detect-wf-meta.js`), SC-6 Final Report rendering (`bin/render-final-report.js`), and SC-7 findings render (`bin/session-close-render-sc7.js`); added `renderFinalReport()` + `buildPostMergeLines()` to `hooks/lib/final-report-schema.js` (SSOT move from stop-final-report-guard); SKILL.md reduced from 222 to 196 lines (HARD limit resolved). <!-- compose-doc-append-sentinel: branch=feature/scriptify-session-close pr=#1480 -->
