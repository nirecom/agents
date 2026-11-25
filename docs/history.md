# History (agents)

## Archived
- [2026](fcff1c6d-55c4-4cd4-87cf-8e0d0cab9ed4-pr3154-history-staging/2026.md) — 93 entries

### FEATURE: PR #3098 — feature/2961-plan-link-plan-presentation-turn (2026-11-17, edc0c0d50863aeb714d4af9906a5949e0beb81d2, #3098)

Background: fix(#2961): hold the plan-link, receipt and continue demands until th...

Changes: #2961 FEATURE: The Stop guard demanded the plan-link line, the receipt and `[confirm-plan] continue:` on mid-turns before the plan review and audit had finished, so a plan URL surfaced too early. Cause: the gate, the Stop guard, receipt recovery and the write-time instruction each judged "may the plan be presented" on their own. A read-only stage readiness judgment (`stageReadiness` in hooks/lib/presentation-readiness.js) is now the shared SSOT, and `auditAdmits` unifies the audit admit/arm/close decision. The `plan-link.js` instruction is three-way (OFF/INTERIM/ON). The glossary term `presentation turn` was renamed `plan presentation turn` (internal). Re-presenting a rewritten, already-approved upstream plan is now an explicit judgment. Known follow-up: readiness has no deadline (LOW; #2936 recovery absorbs the impact). <!-- compose-doc-append-sentinel: branch=feature/2961-plan-link-plan-presentation-turn pr=#3098 -->

### FEATURE: PR #3100 — feature/3067-run-tests-baseline-base (2026-11-17, 5ac973eaea3f44daea550095dc5edb8c62901f81, #3100)

Background: feat(#3067): restore user-approval path for run-tests-baseline outcomes not observable at base

Changes: #3067: run-tests-baseline had lost its way to pass outcomes that the base rerun could not observe (unrunnable-at-base, exit 124/142, rerun classes such as budget-exhausted or worktree-create-failed), so such a failure blocked run_tests with no approval route. The approvable set is now one closed list in disposition.js, and the new sentinel WORKFLOW_RUN_TESTS_BASELINE_UNOBSERVED_ACCEPTED records an approval bound to the HEAD it was given on and to the listed tests; the commit gate run-tests-approval-checker.js checks that binding and the PR body carries an `Unverified tests:` line. A test that passed at base or whose failure lines differ (new-case-failure-on-branch) is never approvable. docs/architecture/claude-code/test-result-contract.md explains what agreeing means. Follow-ups: #3101. <!-- compose-doc-append-sentinel: branch=feature/3067-run-tests-baseline-base pr=#3100 -->

### FEATURE: PR #3105 — feature/3102-npm-latest (2026-11-18, 40d7eff97ad20de5c7efb0abfe36aea5d8cc1f0e, #3105)

Background: feat(#3102): update npm itself to latest in install.ps1 / install.sh

Changes: #3102: Added an "Updating npm" step to install.ps1 and install.sh that updates npm itself to latest (install/win/npm.ps1, install/linux/npm.sh), independent of the Codex/codegraph toggles. It skips when npm is package-manager-managed, not writable, or the latest npm does not support the current Node (install/lib/npm-engine-check.js), and always exits 0. Tests kept minimal (2 cases each for sh and Pester). <!-- compose-doc-append-sentinel: branch=feature/3102-npm-latest pr=#3105 -->

### FEATURE: PR #3107 — feature/3083-bin-step-durations-sentinel-meta (2026-11-18, b29eb83f93d5710272feda4e05b1ee67cb943db8, #3107)

Background: feat(#3083): count sentinel approval and meta-resume idle as wait in step-durations

Changes: #3083: bin/step-durations (scanTranscript in bin/step-durations/sources.js) now counts two more idles as user wait: a Bash call carrying a `<<WORKFLOW_` sentinel, from tool_use to tool_result (approval-hook wait), and the idle from a `stop_hook_summary` to an isMeta resume (peer or meta message), excluding task-notification resumes. Previously only human prompts and AskUserQuestion counted, so net time was overstated. Tests live in the new JS file tests/bin/feature-step-durations-wait.js (21 cases) instead of appending to the .sh test, because the test language follows the code under test (rules/test.md). <!-- compose-doc-append-sentinel: branch=feature/3083-bin-step-durations-sentinel-meta pr=#3107 -->

### FEATURE: PR #3110 — feature/3094-windows-rename-eperm-state-retry (2026-11-18, b678bcda81e76c2c38104195f7ab0d2c931dc4a2, #3110)

Background: fix(#3094): retry win32 EPERM on the workflow-state rename; rebuild invalid command-guard cache entry (#2966)

Changes: BUGFIX #3094: On Windows, the workflow-state write (`writeStateLocked`) failed with rename EPERM while lock-free readers held the state file, so sentinels were not applied. The single `fs.renameSync` now goes through `renameWithRetry` (new leaf module `hooks/workflow-state/state-io/rename-retry.js`): win32 EPERM only, 750 ms deadline, 5-25 ms backoff, original error rethrown when persistent, so the NOT APPLIED path is unchanged. Test gap: real handle contention is not reproducible in CI, so the tests inject EPERM by stubbing `fs.renameSync` and `process.platform`.;BUGFIX #2966: A command-guard test cache entry with an empty or partial `bin/` was never rebuilt, so test setup failed with rename EPERM. `tests/lib/command-guard-build.js` now removes an invalid entry (unlinks only TOOLS-named files, rmdir only on empty dirs, no recursive delete) before rebuilding. Test gap: the rebuild is covered by real Windows builds in `feature-2768-command-guard-ssh-stub.js` (E1-E5). <!-- compose-doc-append-sentinel: branch=feature/3094-windows-rename-eperm-state-retry pr=#3110 -->

### FEATURE: PR #3112 — feature/3102-npm-latest-node (2026-11-19, 1202cee5ac0b1a7ebef9e400db4bfb888a2e7248, #3112)

Background: feat(#3102): update npm to latest in the installers, raising Node via...

Changes: #3102 FEATURE: The Windows and Linux/macOS installers now update npm to latest automatically. When the latest npm cannot run on the current Node, Node is raised first via fnm/nvm (newest of the same major, else LTS). PR #3105 skipped the update on an unsupported Node and missed the goal, so it was redone. If Node cannot be raised, a warning with the manual command is shown and the installer still exits 0. Verified on a real machine: Node 24.14.0 to 24.22.3, npm 12.2.3 (latest). <!-- compose-doc-append-sentinel: branch=feature/3102-npm-latest-node pr=#3112 -->

### FEATURE: PR #3117 — feature/3068-run-tests-baseline-comparison-side (2026-11-20, c2ed721a5bb7c9d9553ca5a05cf64971281291ff, #3117)

Background: feat(#3068 #3069 #3070): add comparison side result parser, data-tabl...

Changes: #3068: Added `parseComparisonSideResult(execOutputs, errHitLines)` (`bin/lib/run-tests-baseline-comparison-side-result.js`), one parser that turns an `rtb_exec_one` call into a comparison side result `{verdict, termination, exitCode, hitKind}` with no comparison side argument, so the branch side and the merge base side get the same facts; only `launcher-setup-failed` and `interrupted-by-outer-watchdog` were added to the file result vocabulary. Background: the two comparison sides read the same `RTB_EXEC_*` in two separate case statements and disagree in six places. Shadow only: the live path is unchanged.;#3069: Added `decide(input)` (`bin/lib/run-tests-baseline-decide.js` + `bin/lib/run-tests-baseline-decide/`), Table 1 / Table 2 rewritten as a data table of mutually exclusive, order-independent rows interpreted by the pure `matchDecideRows`; `decide` throws unless exactly one row matches, and a test enumerates the whole input domain. Details that the four decide inputs cannot produce (`exit-<N>-then-pass`, `base-launcher-predates-result-conversion`, `state-<X>-at-base`, pre-run and reuse-path details) sit in a closed outside-decide list, and the six branch side / merge base side reading differences are recorded with a judgment in `recorded-discrepancies.js` (3 and 4 inconsistent, 6 found during detail planning; the changes they imply are left to #3071). `disposition.js`, `test-result-contract.md` and the live classification are unchanged.;#3070: Added the in-run decide shadow (`bin/lib/run-tests-baseline-decide-shadow.sh` / `.js`): two insertions into `bin/run-tests-baseline` wrap `rtb_exec_one` to capture each run and, after the classification file is written and before the state hand-off, compare decide with the live classification within a 10-second cap, writing a per-run divergence log (30-day retention) and one stderr summary line; `RUN_TESTS_BASELINE_DECIDE_SHADOW=off` disables it. Isolation tests show exit, stdout, state and the classification file are identical with the shadow on, off, failing or hanging. A 10-file synthetic corpus plus the existing reproduction tests assert `unrecorded=0`, and past `baseline_classification` pairs are checked for reachability. <!-- compose-doc-append-sentinel: branch=feature/3068-run-tests-baseline-comparison-side pr=#3117 -->

### FEATURE: PR #3120 — feature/3073-run-tests-main-xfail-pin (2026-11-21, f038a5990c983f935a50c75ed5d48ae2827e5477, #3120)

Background: fix(#3063, #3073): keep split-dispatch failures from vanishing; fix o...

Changes: #3063: failures from split test-runner dispatches no longer vanish. The hook settles every unconsumed dispatch in order under the workflow-state lock; an unknown selection, a truncated run_parts window, an unscannable control dir or a lock timeout keeps run_tests open or pending until a full run. Known gap: the 30-second stale reclaim of the shared lock (lease/fencing left to a follow-up).;#3073: the top 15 failing test files on main were fixed or XFAIL-pinned to #3113 (groups 3 and 4); tests no longer inherit the parent CLAUDE_CODE_SESSION_ID in main-workflow-state-machine, which removed the L3-d pin and fixed L4-c's expected exit code. <!-- compose-doc-append-sentinel: branch=feature/3073-run-tests-main-xfail-pin pr=#3120 -->

### FEATURE: PR #3122 — feature/3019-pm-supervisor-pm-1-md (2026-11-21, eea8407ab0434a5676195c5f51bc88e787b320f8, #3122)

Background: feat(#3019): PM duties SSOT injected by role x timing

Changes: #3019: PM duties now have one SSOT, `skills/_shared/pm-supervisor-duties.md` (recipient H2 x timing H3), injected by role x timing through `hooks/lib/pm-instructions/` and `bin/pm-instructions`: the role comes only from PM state (PM session, PML2, or workflow session whose issue an active PM owns), at SessionStart, post-compact, `/resume-session` and the workflow checkpoints (issue start, companion presentation, plan confirmation, user verification, after Final Report). Lines for mechanisms other issues will build carry `[interim: #NNNN]`, and that issue's PR deletes or rewrites them. Glossary gains PML1, PML2, fixed assignment and temporary assignment. 18 tests the base could not observe within the baseline budget were accepted by the user with UNOBSERVED_ACCEPTED at HEAD b5bcc01. <!-- compose-doc-append-sentinel: branch=feature/3019-pm-supervisor-pm-1-md pr=#3122 -->

### FEATURE: PR #3128 — feature/3127-spawn-env-gh-git-bash (2026-11-22, 02733c2273a3dd192c2e609189a07f39dc29492e, #3128)

Background: fix(#3127): hide console window for gh/git/bash spawns built by spawn...

Changes: #3127 BUGFIX: gh / git / bash spawns built by spawn-env.js lacked windowsHide, so every PM hook flashed a black console window on Windows (bash is a console app; started from a console-less detached node parent, Windows opens a window for it). buildGhSpawn / buildGitSpawn / buildBashScriptSpawn now return windowsHide: true through one shared spawnOpts() helper. The other spawn sites were judged NA: proc.js run() already sets it, and context.js / detect-issues.js are reached only from parents that have a console. A static test (tests/bin/feature-3127-spawn-env-windowshide.js) checks the three builders and that the four callers pass the builder opts through; whether a real Windows run shows no window stays a documented TL3 gap. Three run_tests failures (feature-920, feature-1117, feature-1305) also fail at the merge base and are unrelated to this change. <!-- compose-doc-append-sentinel: branch=feature/3127-spawn-env-gh-git-bash pr=#3128 -->

### FEATURE: PR #3129 — feature/2168-extract-field-capture (2026-11-22, 8476be45cc7a42d845e6b124c86e1f642023bb1a, #3129)

Background: fix(#2168): end extract_field capture only at known labels

Changes: BUGFIX #2168: extract_field ended capture at any `###` heading right after `## Background`, silently dropping most of the body from issue-to-history entries. Capture now ends only at `##` or at a `###`–`######` heading naming a known label (Background / Changes / Cause / Fix / `Sub-tasks (optional)`, including ATX closing hashes); other sub-headings stay in the value and seven or more `#` are plain text. A parity test checks the label set against `.github/ISSUE_TEMPLATE`. Out of scope: truncation detection and re-conversion of existing history. <!-- compose-doc-append-sentinel: branch=feature/2168-extract-field-capture pr=#3129 -->

### FEATURE: PR #3130 — feature/2942-pm-supervisor-s3-pm-forge (2026-11-22, e5352bf366920f3632f34d51e19b6d115f7325b1, #3130)

Background: feat(#2942): link issues to a PM and notify the PM from workflow sess...

Changes: #2942: Issues now name their owner PM through the Projects v2 `pm` field (`bin/lib/pm-field/`, fail-closed on conflicting cards). `bin/pm-notify` records, delivers, retries and settles PM notifications under a PM lock, with a SessionStart inbox for the PM session. `/workflow-init` gains a pm-scan phase with one batched owner lookup; `/pm-rename` is added and `/pm-add`, `/pm-remove`, `/pm-init` write the forge field. Pre-PR PM contact is backed by `pm-notify check-header`. <!-- compose-doc-append-sentinel: branch=feature/2942-pm-supervisor-s3-pm-forge pr=#3130 -->

### FEATURE: PR #3131 — feature/2478-codex-review-loop-cc-fallback (2026-11-22, 2698fbce19e0fe4a920ef646a852311e7b86e5ec, #3131)

Background: feat(#2478, #3123): run CC fallback review rounds through the codex review-loop path

Changes: #2478: CC fallback review rounds now re-enter bin/run-codex-review-loop with --prestaged-report for all four plan/test formats, so the round counter, the 2+1 cap, the concern ledger and reject carry-over apply to them exactly as to codex rounds. An unrecorded fallback round is undone from a snapshot taken under the round lock.;#3123: removed the separate record-fallback / fallback-pending route and the dead ends after a codex exit 3 (no pending, terminal marker blocking the re-run, WARNINGS_ACCEPTED refused); review-tests now runs its fallback through skills/review-tests/scripts/run-fallback-review.sh. <!-- compose-doc-append-sentinel: branch=feature/2478-codex-review-loop-cc-fallback pr=#3131 -->

### FEATURE: PR #3134 — feature/3127-hook-child-process-windowshide-static (2026-11-22, 84d2a82b62977abc294956b72303cfc7a689c8b9, #3134)

Background: fix(#3127): hide console window for hook/bin child spawns and scan th...

Changes: #3127 (BUGFIX, follow-up to PR #3128): hook and PM child spawns still flashed a console window on Windows. Added `windowsHide: true` to the shared wrappers (`hooks/lib/limited-child-process`, `hooks/lib/spawn-shimmed-cli.js`) and to 45 direct `hooks/**` / `bin/**` spawns. Added a glob full-scan static test over `hooks/**` and `bin/**` (shared scan helper under `tests/lib/windows-hide-scan/`) with a reason-bearing allowlist for variable-cmd and manually run CLIs; no require-graph tracing. run_tests was approved via BASELINE_UNOBSERVED_ACCEPTED for 4 tests at HEAD 92dae50 only. review_security ran as a PM-infra substitute review because codex hit its usage limit and the security-scanner agent lacks the Write tool (same class as #1301). <!-- compose-doc-append-sentinel: branch=feature/3127-hook-child-process-windowshide-static pr=#3134 -->

### FEATURE: PR #3137 — feature/1610-worktree-repo-claude-worktrees-enterwork (2026-11-23, 6d79bf77ea3d542f8590a2b0bc57670e8ba279d0, #3137)

Background: feat(#1610, #1849): default the worktree base to <repo>/.claude/workt...

Changes: #1610: the default worktree base is now `<repo>/.claude/worktrees` (layout `<base>/<task>/<repo>` unchanged). One resolver, `hooks/lib/worktree-base.js` (CLI `bin/worktree-base`), owns the base (`WORKTREE_BASE_DIR` when set), and worktree-start, worktree-copy, `bin/worktree-write-notes.js`, sweep-worktrees, the review-* prune, enforce-worktree, cleanup-orphan-dir and preuse-auto-approve all resolve it there; copy and `find .` exclusions derive from the resolved base. cleanup-orphan-dir refuses `--force-if-not-registered` when no repo resolves; the explicit-base fallback allows only an empty-dir rmdir. Existing worktrees under the old base were not moved (PM decision: each owning session closes its own with /worktree-end). Follow-up: symlinked `.claude/worktrees` and Windows letter-case mismatch in `WORKTREE_BASE_DIR` (security review MEDIUM).;#1849: removed the EnterWorktree auto-approve branch from preuse-auto-approve, since an in-repo base needs no dialog. The Monitor branch, its `settings.json` matcher entry and `AUTO_APPROVE_TOOLS` stay, pinned by a test. <!-- compose-doc-append-sentinel: branch=feature/1610-worktree-repo-claude-worktrees-enterwork pr=#3137 -->

### FEATURE: PR #3140 — fix/3135-fix-pm-pm-field-pm (2026-11-23, 233698625c0018efbc262764e283a6f495be6b3d, #3140)

Background: fix(#3135): treat a Project without the pm field as undecidable, not as no-owner, and repair it through migrate-tracker

Changes: #3135: fix(pm): a Project without the pm field is now undecidable for owner lookup instead of failing with gh_exec_failed; migrate-tracker repairs it by creating the field, re-judging and backfilling idempotently under the PM lock. <!-- compose-doc-append-sentinel: branch=fix/3135-fix-pm-pm-field-pm pr=#3140 -->

### BUGFIX: PR #3141 — feature/3138-worktree-base-path-checks-in (2026-11-24, cec54b2ae1587f76a524f8826847c55429797c2a, #3141)

Background: fix(#3138): detect the in-repo worktree base by realpath and fold let...

Changes: #3138: in-repo worktree base detection is now realpath-based and fail-closed (a symlinked or junctioned `.claude/worktrees` gets no create exemption), and letter case is folded on Windows/macOS only through the shared `hooks/lib/path-real-fold.js` rule (`isInRepoBase`, `inRepoRelative`, `underAnyRoot`, `worktree-base-prune.sh`). Both global-gitignore installers now list `.claude/worktrees/`. Case-sensitive APFS and the Linux CLI-failure prune are accepted known limitations; a parent directory that cannot be listed (for example POSIX mode 0311) makes the in-repo check fail closed. The pwsh installer's append path now adds the blank line the replace path adds, so a second run leaves the file unchanged. <!-- compose-doc-append-sentinel: branch=feature/3138-worktree-base-path-checks-in pr=#3141 -->

### FEATURE: PR #3148 — feature/2020-cat-d-codex-threat-model (2026-11-24, 4c0d6d0338245de8f36754f2d5cd55b6d0ddf4e9, #3148)

Background: feat(#2020): declare the threat-model boundary to codex reviews and measure its effect

Changes: #2020: Added a versioned threat boundary (`## Threat boundary`, v1) to the review criteria so codex and the CC fallback reviewers mark out-of-boundary or no-input-path security threats as `[NOT-CONCERN]` instead of numbered concerns; the concern journal now records every round's concerns with their boundary version (written once, after the wrapper's exit code is known), and `bin/review-threat-metrics` measures pre boundary vs post boundary results per version. <!-- compose-doc-append-sentinel: branch=feature/2020-cat-d-codex-threat-model pr=#3148 -->

### FEATURE: PR #3153 — feature/3144-pm-session-pm-review-pre (2026-11-25, 6796519124c63869d9e070250c44ce81b0aad26d, #3153)

Background: feat(#3144): route the plan-stage pre-confirm audit to the assigned PM

Changes: #3144: The plan-stage pre-confirm audit (CONFIRM_INTENT / OUTLINE / DETAIL) is now routed to the assigned PM; the PM verdict (CONTINUE / WARN / BLOCK) is recorded in the supervisor state. When the PM does not answer after one retry, the user chooses between re-requesting the PM and the conventional audit supervisor; an unsettled review uses the same 2+1 counter and then asks the user.;#2991: The assigned PM now reviews the PR before the user_verified step, sharing the same request protocol, so the release approval no longer relies on the conventional supervisor audit alone. <!-- compose-doc-append-sentinel: branch=feature/3144-pm-session-pm-review-pre pr=#3153 -->

### FEATURE: PR #3154 — feature/3151-rules-ops-md-diverged-main (2026-11-25, c95ce4ec4a09369149b75bcba94bcb0ad664be28, #3154)

Background: fix(#3151): refuse the diverged-main merge shortcut when the remote h...

Changes: #3151: Diverged main worktree recovery no longer merges when the remote history was force-updated. Background: the #1982 merge allow re-introduced the pre-rewrite history after a remote rewrite. Changes: rules/ops.md tells rebase --onto first and reset --hard only with no local commit, both under user escalation. standard.js allows the merge only when git merge-base --is-ancestor origin/<b>@{1} origin/<b> succeeds and blocks it when the reflog is missing. user-escalation.md and worktree.md now point to the ops.md SSOT. Known limit: a forced update followed by a fast-forward fetch is not detected, because the check looks at the last fetch only. <!-- compose-doc-append-sentinel: branch=feature/3151-rules-ops-md-diverged-main pr=#3154 -->


