### FEATURE: Add CHANGELOG.md — automated via /update-docs (2026-05-04)
Background: update-docs now writes to both docs/history.md (internal) and CHANGELOG.md (user-facing) in one run.
Changes: CHANGELOG.md is now automatically maintained. Each update-docs run appends a user-facing summary entry. doc-append accepts --commits as optional, enabling date-only headers suited for a public changelog.

### FEATURE: Gemini CLI + mmdc integration; draw-mermaid skill; installer flags (2026-05-04)
Background: Gemini CLI and Codex CLI are now optional, installed only with the -Develop flag to keep the default install lightweight.
Changes: New /draw-mermaid skill generates Mermaid diagrams via subagent (dark-mode-safe colors, WCAG 2.1 AA). Workflow flowchart added to README. install.ps1 -Develop / install.sh --develop installs Codex CLI + Gemini CLI + Mermaid CLI (mmdc); default install covers Claude Code only. Gemini API image generation supported via bin/draw-diagram-gemini (paid plan required).

### SECURITY: Strengthen settings.json deny rules; add security-policy.md (2026-05-04)
Background: Push deny rules had coverage gaps.
Changes: Deny rules now cover additional push flag variants. New docs/security-policy.md documents the permission model. README updated to highlight deny-list as a security feature.

### SECURITY: Block Claude Code writes to .private-info-allowlist (2026-05-04)
Background: In VSCode ask-before-edits mode, permissions.deny rules for Edit/Write are bypassed, so CC could silently append exceptions to the scan-outbound allowlist.
Changes: The block-dotenv.js PreToolUse hook now blocks all Edit/Write access to .private-info-allowlist. Exceptions must be added manually.

### FEATURE: Workflow: clarify-intent now mechanically enforced before Edit/Write (2026-05-04)
Background: Previously Claude would often skip /clarify-intent at session start despite CLAUDE.md instructions, requiring users to manually redirect to the workflow.
Changes: PreToolUse hook now blocks Edit/Write/MultiEdit/editFiles/NotebookEdit until clarify_intent step is complete or skipped. Read/Grep/Glob/Bash remain available for investigation and skill execution. Skip path: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: <reason>>". Recovery: echo "<<WORKFLOW_RESET_FROM_clarify_intent>>". TodoWrite checklist creation moved into the clarify-intent skill's Completion section.

### FEATURE: scan-outbound: add warn: prefix for soft-block blocklist patterns (2026-05-04)
Background: Hard-only blocklist made it hard to register suspicious-but-uncertain patterns without false-positive noise.
Changes: Prefix any line in .private-info-blocklist with warn: to mark it as a soft-block pattern. On match, Claude Code asks for user confirmation; interactive git commit prompts y/N via /dev/tty; non-interactive contexts (CI, no TTY) auto-block as a safe default. Hard-block patterns continue to fail immediately and win over warn when both match. Scanner exit code 2 is now reserved for warn-only; the previous usage-error code moved from 2 to 3 (breaking change for any external script that parsed exit 2).

### REFACTOR: blocklist: add warn: examples to .private-info-blocklist.example (2026-05-06)
Background: The .example file is many users' first reference for the blocklist format; without a sample, the new warn: prefix was discoverable only by reading docs/scan-outbound.md.
Changes: Added a commented warn: section to .private-info-blocklist.example with two illustrative patterns and a pointer to the docs section that explains the soft-block UX matrix.

### FEATURE: Parallel sessions: enforce worktree, mandatory PR, global gitignore (2026-05-06)
Background: Concurrent agent sessions could race on the default branch when both wrote to main. No mechanism prevented main-checkout edits even with feature branches checked out.
Changes: ENFORCE_WORKTREE=on (default) blocks all Edit/Write/Bash-write operations from the main checkout regardless of branch — work must happen in a linked worktree (/worktree-start). Worktrees follow a standard <WORKTREE_BASE_DIR>/<task>/<repo> path layout. /worktree-end now requires PR + merge as the only exit path. Installer adds a global gitignore block for WORKTREE_NOTES.md (idempotent on Linux/macOS/Windows). Set ENFORCE_WORKTREE=off in agents config to opt out for trivial direct-main work. Action required: rename AGENT_AUTO_BRANCH → ENFORCE_WORKTREE and AGENT_DEFAULT_BRANCHES → DEFAULT_BRANCHES in your agents config now. The old names are deprecated and will be removed.

### BUGFIX: global-gitignore.ps1: .Count error on empty/single Where-Object result (2026-05-06)
Background: install.ps1 errored at the global-gitignore step on first run when the gitignore file contained no agents-managed markers — Where-Object returned 0 items (null) and .Count failed.
Changes: Wrap Where-Object pipeline in @() array context so .Count is always safe regardless of result count.

### FEATURE: commit-gate redesign: merge boundary enforcement + staged diff fallback (2026-05-07)
Background: The commit gate had three design issues causing friction: user_verification fired prematurely on intermediate feature-branch commits, push detection reset verification state on every push including feature-branch pushes, and review-code-codex skipped review on fresh branches with no committed changes.
Changes: Merge gate now hard-blocks gh pr merge and git push to protected branches until user_verification is complete. Feature-branch commits in linked worktrees skip the user_verification gate (verification fires at merge time instead). workflow-mark resets verification only after protected-branch push or PR merge. review-code-codex falls back to staged diff when no commits exist past the base branch.

### BUGFIX: enforce-worktree: allow git worktree and directory-creation commands from main checkout (2026-05-07)
Background: /worktree-start was bootstrapping itself into a deadlock — the commands needed to create a worktree were blocked by the very guard they were trying to satisfy.
Changes: git worktree add/remove/prune and the PowerShell directory-creation cmdlet are now permitted from the main checkout, with safety guards: chained commands are still blocked, and paths that resolve inside the main repo root are still rejected.

### REFACTOR: rename workflow step branching_decision → branching_complete (2026-05-07)
Background: The old name "branching_decision" implied a choice; with ENFORCE_WORKTREE=on a worktree is mandatory so no decision is made. The new name aligns with the _COMPLETE naming convention used by all other workflow sentinels.
Changes: Internal step key and sentinel renamed across all hook files and skill docs. Old sentinel WORKFLOW_BRANCHING_DECIDED is still accepted (backward compatible). Existing session state files with the old key are migrated automatically on first read.

### BUGFIX: workflow sentinel echo no longer blocked by write-guard when ENFORCE_WORKTREE=on (2026-05-07)

### FEATURE: enforce-worktree: EXTRA_REPOS directory-scan fallback (depth 1) (2026-05-07)
Background: Users had to list every repo path individually in ENFORCE_WORKTREE_EXTRA_REPOS even when all repos share a common parent directory.
Changes: ENFORCE_WORKTREE_EXTRA_REPOS now accepts parent directories in addition to individual repo paths. Any entry that is not itself a git repo is scanned one level deep; all git repos found inside are added to the session scope. Mixed lists (individual paths and parent dirs) work as expected, and spaces around commas are trimmed.

### BUGFIX: git worktree add no longer blocked on Windows + Git Bash (2026-05-07)
Background: On Windows with Git Bash, running git worktree add via the Bash tool could be falsely blocked even when the target path was outside the repo.
Changes: isPathOutsideRepo now normalizes POSIX drive-letter paths (e.g. /c/git/foo) to Windows-native form before resolving them. This fixes the misresolution that caused outside paths to appear inside the repo on Windows Node.js.

### BUGFIX: bash-write-patterns: /dev/null null-sink misclassified as write (2026-05-08)
Background: Read-only redirects to /dev/null (e.g. `git status 2>/dev/null`) were classified as write commands and blocked by the enforce-worktree guard from the main checkout.
Changes: /dev/null null-sink redirects (`2>/dev/null`, `>/dev/null`, `&>/dev/null`, `>>/dev/null`) are now correctly classified as read. Subpaths like `/dev/null/foo` and the documented `2>&1` false positive remain as write.

### FEATURE: ENFORCE_WORKTREE_EXCLUDE: bypass worktree gate for matched files + doc-append-plain command (2026-05-08)
Background: ENFORCE_WORKTREE blocked all main-checkout commits, including low-risk doc appends to shared todo files across repos.
Changes: New ENFORCE_WORKTREE_EXCLUDE env var accepts semicolon-separated glob patterns. When all staged files match a pattern, the main-checkout and protected-branch gates in pre-commit are skipped (private-info scan still runs). New doc-append-plain command for append-only plaintext writes to doc files. BREAKING CHANGE: ENFORCE_WORKTREE_EXTRA_REPOS separator changed from comma (`,`) to semicolon (`;`) — if you set this variable, update your `.env` before upgrading.

### BUGFIX: fix worktree-to-main flow: hook false-positives (2026-05-08)
Background: Several PreToolUse hook bugs were blocking the standard worktree-to-main merge workflow (PR create / merge / cleanup) and a security review surfaced additional bypass risks.
Changes: git branch -d (delete merged branch) is now classified read, not write. git-branch-mutate regex no longer false-positives on branch names containing -d/-c (e.g. feature-env-consolidate). gh pr/issue create/edit/comment with heredoc body is no longer blocked from main checkout. git pull/merge --ff-only is now allowed from main checkout (the operation main is reserved for). git update-ref is now classified write. block-dotenv hook now uses a path-position parser instead of a free-text regex: gh PR/commit messages containing the literal string .env no longer false-positive, while real .env access (including via command substitution like $\(cat .env\), redirect like echo > .env, and shell wrappers like bash -lc "cat .env") still blocks.

### FEATURE: global-gitignore.ps1: Pester integration tests (2026-05-08)
Background: The Windows installer for global gitignore (install/win/global-gitignore.ps1) had no automated tests; a null-reference bug was only caught in production.
Changes: Added 15 Pester integration tests covering normal, idempotency, edge, error, and security cases. The .Count null-reference bug from production is now caught by the double-run idempotency test (T04).

### FEATURE: planner draft persistence + cross-stage context propagation (2026-05-09)
Background: Planner draft files were written to OS temp and got lost to OS cleanup or context compaction, requiring planner subagent restart. Cross-stage context (intent and outline) was also missing from codex plan review, causing out-of-scope reviewer concerns, and show-diff previewed every draft revision, interrupting the planner/reviewer loop.
Changes: Planner drafts now persist under ~/.claude/plans/drafts/. Plan-stage context (intent and outline) is automatically passed to the codex plan reviewer. show-diff suppresses preview for draft files only — final plan artifacts still show diffs. Fallback session-id format simplified to a plain timestamp.

### BUGFIX: POSIX file copy/move to non-session paths no longer falsely blocked; PowerShell migration command (2026-05-09)
Background: Copying or moving files to a destination outside the current session repo was blocked by the worktree-write guard because the destination was not parsed. The plans-directory migration runbook in docs/ops.md was bash-only, leaving Windows users to translate the command themselves.
Changes: POSIX copy and move commands with destinations resolving outside session scope are now allowed (mirroring the existing redirect/tee/PowerShell extractor behaviour). docs/ops.md gained the PowerShell version of the plans-directory migration command.

### REFACTOR: branch delete now requires worktree-end skill; main worktree terminology aligned to Git official term (2026-05-09)
Background: Earlier PRs landed two hacks: classifying soft/force branch-delete flags as read so the worktree-write guard would not block them, and using project-internal jargon for the original repository directory. The read classification was location-axis thinking — the right axis is the target branch's worktree binding. The jargon term diverged from Git's official term and made cross-referencing official Git documentation harder.
Changes: Soft and force branch deletion are now classified as write again. The only authorized path is the /worktree-end skill, which writes a marker file before deletion; the hook validates the marker against the target branch and the recorded worktree path. Direct ad-hoc branch deletion from any worktree is rejected — /worktree-end is the only path. Project-wide terminology now uses Git's official 'main worktree' (vs 'linked worktree') in user-facing error messages, rules, skills, README and CLAUDE.md. The settings.json deny rules for branch-delete commands were removed (no longer needed; the hook governs).

### CONFIG: ENFORCE_WORKTREE_EXCLUDE comment rewritten user-side; new content rule for .env.example (2026-05-10)
Background: The .env.example comment for ENFORCE_WORKTREE_EXCLUDE described internal hook behaviour that an end user reading the file does not know. There was also no convention defining what belongs in .env.example, so prior edits had drifted into PR-reference and implementation-detail territory.
Changes: Rewrote the ENFORCE_WORKTREE_EXCLUDE comment to cover only what the user can do, what they can't do, and the value format. rules/docs-convention.md gained a new content rule for .env.example codifying these three required items, applicable going forward to all .env variables.

### FEATURE: User escalation rules: autonomy-first and safe command presentation (2026-05-11)
Background: Claude Code was asking users to run commands that it could execute itself, and presenting multiple commands in a single ask.
Changes: Claude Code now tries tools before asking the user to run anything (Autonomy-First). When a user ask is unavoidable, exactly one command is presented at a time and the next step is only shown after the user reports the result (One-Command-at-a-Time). When multiple non-destructive steps must run in sequence, they are bundled into a single fail-fast script so the user is asked once, not once per step (Script-First).

### FEATURE: GitHub Issues migration foundation: /issue-close, sub-issue gate, reconcile (2026-05-11)
Background: Adds the foundation for migrating per-repo work tracking to GitHub Issues. Covers structured issue templates, a label schema, and a transaction-safe close pipeline that atomically appends every closed issue to docs/history.md before calling gh issue close.
Changes: New /issue-close skill: closes a GitHub Issue safely, in 9 steps — including sub-issue gate (blocks parent close when any child is still open), 2-phase pending/appended sentinel comment on the issue for crash recovery, automatic history.md append, and todo.md cleanup. New /issue-reconcile skill: backfills history.md for issues that were closed outside Claude Code (web UI, mobile, other terminal). New enforce-issue-close.js hook blocks bare gh issue close calls not routed through the skill, preventing history.md misses. GitHub Issue templates for task and incident workflows; label schema with bin/sync-labels.sh for idempotent label creation.

### FEATURE: CONFIRM_OUTLINE/DETAIL/WORKTREE/TESTS env flags (2026-05-11)
Background: Confirmation prompts at outline / detail / worktree-start (file copy) / write-tests stages were unconditional, slowing the workflow.
Changes: Add CONFIRM_OUTLINE, CONFIRM_DETAIL, CONFIRM_WORKTREE, CONFIRM_TESTS env flags (default on). When set to off, the relevant skill displays the final result and auto-continues without AskUserQuestion. Per-round planner/reviewer noise is no longer printed to chat - diagnostics go to <session-id>-{outline,detail}-debug.log instead. New helper bin/get-config-var (POSIX + PowerShell) reads .env values via hooks/lib/load-env.js with a --is-off subcommand for parity with hooks/enforce-worktree.js on/off semantics.

### REFACTOR: rules: scope rule files to relevant file types (session overhead reduction) (2026-05-12)
Background: All rule files loaded globally at session start, consuming context window capacity even when irrelevant to the current task.
Changes: Split large rule files into path-scoped sub-files that load only when editing matching file types (docs/*.md, *.py, *.ts, docker-compose.yml, test files, etc.). Test design rules (categories, naming conventions, layer selection) moved to skills/test-design-shared/reference.md — loaded by write-tests/review-tests only. Corrected globs: frontmatter in files that had used the unsupported paths: key.

### FEATURE: Delivery plan surfaced at outline stage; importance-first detail plan sections (2026-05-12)
Background: The delivery plan (execution order, split policy) was previously buried in detail.md without being agreed at outline stage.
Changes: Each approach option in /make-outline-plan now includes a Delivery plan field, and a prose rationale is shown before the AskUserQuestion so users have context to choose. /make-detail-plan surfaces the outline delivery plan to the main conversation before planning begins. Detail plans now open with the Delivery plan section first (importance-first ordering). When CONFIRM_OUTLINE=off, /clarify-intent captures delivery plan direction so it is never lost.

### BUGFIX: /worktree-end marker cleanup now completes without manual intervention (2026-05-12)
Background: /worktree-end step 6g failed to delete the branch-delete marker file after merging because the deletion was blocked by the write guard.
Changes: Marker cleanup at step 6g now runs automatically. git push -u origin <branch> from inside a worktree no longer prompts for permission.

### FEATURE: Planning workflow no longer prompts for routine skill operations (2026-05-12)
Background: Permission prompts interrupted the planning workflow for get-config-var flag checks, reading prior-stage plan files, and debug log writes.
Changes: Planning skills (clarify-intent, make-outline-plan, make-detail-plan, write-tests, worktree-start) now run without permission prompts for their standard Bash and Read operations.

### BUGFIX: /worktree-end keeps local main in sync with origin (2026-05-12)
Background: After /worktree-end merged a PR, local main stayed at the pre-merge commit, so newly merged files were not visible until the next manual pull.
Changes: /worktree-end step 6h now fast-forwards local main to origin after fetching. Uses --ff-only, so a diverged local main halts the step with a non-zero exit instead of silently merging.

### FEATURE: planning pipeline UX improvements (2026-05-12)
Background: Intermediate plan draft files triggered permission dialogs on every revision round; Write diff previews showed a plain header instead of actual diffs.
Changes: Intermediate planning draft files (written during /make-outline-plan and /make-detail-plan) no longer trigger permission dialogs. Write operations now show proper diff previews: new files display a /dev/null header with all lines as additions; overwrites show a real diff against the existing file content.

### BUGFIX: pending-branch-delete marker no longer prompts on create / edit / delete (2026-05-12)
Background: /worktree-end writes the pending-branch-delete marker from the main worktree before deleting the merged branch. Each write triggered a permission prompt, and deleting a stale marker left over from an aborted run also prompted.
Changes: Writing, editing, or deleting <git-common-dir>/info/pending-branch-delete from the main worktree no longer triggers a permission prompt. Deleting a non-existent marker is treated as a safe no-op.

### BUGFIX: CONFIRM_* flags now take effect when working from the main worktree (2026-05-12)
Background: Planning skills probe CONFIRM_OUTLINE, CONFIRM_DETAIL, and similar flags by running a shell command from main. That command was classified as a write and blocked, so the flags were always treated as on regardless of the configured value.
Changes: The specific probe shape used by planning skills is now permitted from the main worktree. CONFIRM_* flags set to off are honoured in all session contexts.

### FEATURE: Fixup commits no longer require re-verification (2026-05-12)
Background: Small fixup commits made after user_verification was already granted re-triggered the full verification gate, requiring user approval again even for low-risk intermediate changes.
Changes: Running git commit as git -c workflow.wip=1 commit -m "..." (or via /commit-push --wip) skips user_verification for that commit only. All other gates (run_tests, review_security, docs) still apply. The next non-WIP commit re-triggers verification as normal.

### FEATURE: Test output now runs in a dedicated subagent, keeping the main session clean (2026-05-13)
Background: Test output was accumulating in the main conversation, consuming token budget and obscuring context.
Changes: Step 6 now delegates test execution to a test-runner subagent. Only a compact YAML summary (pass/fail status, failing test names, last 40 log lines) returns to the main session. A dual sentinel prevents stale pass state from surviving a newly failing test run.

### BUGFIX: enforce-worktree unblocks docs push, read-only config checks, and orphan-dir cleanup (2026-05-13)
Background: Three git workflow operations were incorrectly blocked by the write guard in the main worktree.
Changes: git push origin main from the main worktree is now allowed when every file in the outgoing commits is covered by the exclude pattern (e.g., docs-only changes). Read-only bash -c invocations (such as config flag checks used by planning skills) are no longer blocked. After git worktree remove, the leftover empty directory can now be cleaned up via a dedicated node script instead of the blocked recursive-delete approach.

### FEATURE: Work tracking migrated from docs/todo.md to GitHub Issues (2026-05-13)
Background: Commits to docs/todo.md caused merge conflicts across concurrent sessions, blocking push and worktree cleanup.
Changes: Open tasks are now GitHub Issues (#222-#245 in nirecom/agents). docs/todo.md is now a one-line-per-issue index; open the issue for full context. Browse all tasks in chronological order via the 'agents — Issue Timeline' project board (Content Date field).

### BUGFIX: show-diff no longer previews plan files outside drafts/ (2026-05-13)
Background: Diff preview suppressed only planning draft files, not final plan artifacts (intent, outline, detail).
Changes: All files under ~/.claude/plans/ are now excluded from diff preview (previously only plans/drafts/).

### BUGFIX: Pre-commit .env guard now correctly skips private repos (2026-05-13)
Background: Private GitHub repos and non-GitHub remotes were blocked when staging a new .env file.
Changes: Private repos and non-GitHub remotes now skip the .env-add check. Public GitHub repos continue to block direct .env commits. Also: hook-disabling git commands (git -c core.hooksPath=..., GIT_CONFIG_PARAMETERS=..., etc.) are now blocked even from linked worktrees.

### FEATURE: Planning skills: eliminate VS Code permission dialogs for plan file writes (2026-05-13)
Background: VS Code's ask-before-edits mode bypasses settings.json allow rules for Write/Edit tools — planning skill writes to ~/.claude/plans/ triggered repeated permission dialogs on every session.
Changes: Planning skill file writes (clarify-intent, make-outline-plan, make-detail-plan) no longer prompt for permission in VS Code. Writes to ~/.claude/plans/ and its subdirectories are auto-approved via a new PreToolUse hook.

### FEATURE: Planning skill writes no longer trigger VS Code permission dialogs (2026-05-14)
Background: Planning artifacts were stored under ~/.claude/plans/ — a path protected by Claude Code — causing VS Code ask-before-edits mode to prompt on every Write/Edit call during planning sessions.
Changes: Planning artifacts moved to ~/.workflow-plans/ (configurable via WORKFLOW_PLANS_DIR env var). Permission dialogs no longer appear during clarify-intent, make-outline-plan, and make-detail-plan skill runs in any mode. Existing ~/.claude/plans/ contents are migrated automatically on first run. Customise the path by setting WORKFLOW_PLANS_DIR=/absolute/path in your agents .env.

### BUGFIX: Planning confirmations now respect CONFIRM_* flags; plan diffs visible again (2026-05-14)
Background: Planning skill confirmations were always triggered by the protected .claude/ path, regardless of CONFIRM_* flag settings.
Changes: Confirmations now follow CONFIRM_INTENT/OUTLINE/DETAIL flags reliably — prompting only when the flag is on. Final plan artifacts (intent.md, outline.md, detail.md) now show diffs again; they were previously suppressed alongside draft files.

### BUGFIX: issue-to-history.sh: correct date, header format, and idempotency (2026-05-14)
Background: issue-to-history.sh produced history entries with wrong dates and malformed headers due to missing --date, wrong argument names, and an incomplete idempotency check.
Changes: History entries now use the issue's actual close date. The issue number is embedded in the header (parenthetical format). Duplicate-append detection now recognises both old and new header formats.

### FEATURE: clarify-intent auto-detects the GitHub issue being closed (2026-05-14)
Background: The issue number to close had to be remembered and passed manually to /issue-close at the end of a session.
Changes: clarify-intent now detects #N references in your opening message and records the issue as closes_issues — no extra question asked when unambiguous. CLAUDE.md Step 10 now reminds you to invoke /issue-close <N> using the recorded number.

### BUGFIX: Planning workflow: plan artifact links now always shown before auto-proceeding (2026-05-14)
Background: In CONFIRM_*=off mode the planning workflow would skip the clickable link to intent.md / outline.md / detail.md and proceed directly, leaving no record in chat of what was written.
Changes: Clickable absolute-path links to intent.md, outline.md, and detail.md are now shown in chat before auto-proceeding, regardless of CONFIRM_* flag setting. Also: make-outline-plan's single-approach path now correctly surfaces the artifact link and respects the revise loop.

### BUGFIX: C:/Program Files/Git/worktree-end marker writes no longer trigger permission prompts (2026-05-14)
Background: The branch-delete marker written by /worktree-end was stored inside .git/ — a Claude Code protected path — causing permission prompts in default and acceptEdits modes even with settings.json allow rules in place.
Changes: Marker moved to ~/.workflow-plans/worktree-end/ (same pattern as the .claude/plans/ → ~/.workflow-plans/ fix). /worktree-end marker writes and deletes no longer trigger permission prompts in any mode. The marker path is configurable via WORKFLOW_PLANS_DIR.

### FEATURE: issue-fix-history cross-reference (#222) (2026-05-14)
Background: Issues closed via closes #N in PR descriptions left no history.md entry.
Changes: `/issue-close` now recovers from GitHub auto-close (no re-close needed) and posts a resolved-by commit comment. New backfill script covers past closed issues. docs/todo.md is now a GitHub Issues pointer only.

### FEATURE: Workflow now routes based on GitHub issue context at session start (2026-05-14)
Background: Each workflow session now begins with /workflow-init, which inspects whether a GitHub issue number was provided and whether it carries the intent:clarified label.
Changes: If you pass #N with the intent:clarified label: the interview is skipped and the issue body is used directly as the agreed requirements — no questions asked. If you pass #N without the label: the interview is pre-filled from the issue body; you confirm or revise framing rather than starting from scratch. If no issue is given: the full clarify-intent interview runs as before, and a tracking issue is auto-created at the end. clarify-intent now applies the intent:clarified label to the issue on completion, so future sessions on the same issue automatically take the fast path.

### FEATURE: show-plan-link.js: reliable plan file path display via PostToolUse hook (2026-05-15)
Background: The confirm-plan protocol's Step 2 (showing the written plan file path) was executed by the LLM, making it unreliable across sessions — tildes, Windows backslashes, and a VS Code extension webview bug prevented clickable links.
Changes: Plan file path now always appears in chat via a deterministic PostToolUse hook instead of LLM instruction. When running inside the VS Code extension, the hook also opens the file in the current window automatically.

### BUGFIX: /issue-close skill bypass fix + worktree cleanup stability (#267, #268, #251) (2026-05-15)
Background: Two hook bugs caused /issue-close and post-worktree commands to fail silently.
Changes: /issue-close now works correctly when the skill passes ISSUE_CLOSE_SKILL=1 as an inline env-var prefix (the fix detects the exact canonical shape). After /worktree-end removes a worktree, subsequent commands no longer fail with a dead working directory — enforce-worktree.js now fails open with an audit log line. On Windows, git worktree remove no longer fails with EPERM: /worktree-end now switches the session CWD to the main worktree before removing the linked one.

### CONFIG: Auto-sync labels.yml to GitHub (2026-05-15)
Background: Manual sync was required after editing .github/labels.yml.
Changes: Merging to main now triggers a GitHub Actions workflow that applies labels.yml to the repository automatically.

### FEATURE: worktree-start / worktree-end hidden from slash-command autocomplete (#281) (2026-05-15)
Background: /workflow-init shared the 'work' prefix with worktree-start and worktree-end, requiring 5 keystrokes to uniquely complete.
Changes: /workflow-init can now be launched by typing 'wo' + Enter — worktree-start and worktree-end no longer appear in the / autocomplete menu.

### FEATURE: Skill size review at workflow Step 6 (#284) (2026-05-15)
Background: Skill definitions tend to grow verbose over time.
Changes: A new non-blocking review step (review-skill-size) now runs automatically in parallel at workflow Step 6 whenever a SKILL.md file is changed. It warns when a skill exceeds 100 lines and always prints a checklist of qualitative improvements to consider.

### FEATURE: Skill size review at workflow Step 6 (#284) (2026-05-15)
Background: Skill definitions tend to grow verbose over time.
Changes: A new non-blocking review step (review-skill-size) now runs automatically in parallel at workflow Step 6 whenever a SKILL.md file is changed. It warns when a skill exceeds 100 lines and always prints a checklist of qualitative improvements to consider.

### FEATURE: New /issue-create skill — create task issues with automatic Projects v2 attachment (2026-05-15)
Background: No sanctioned way existed to create type:task issues from a Claude Code session without risking missing labels or forgetting the Projects v2 attachment step.
Changes: New /issue-create skill creates type:task issues and attaches them to Projects v2 automatically. Caller-supplied type:* labels are rejected (use raw gh issue create for incident issues). Projects v2 attach failure is non-fatal — the issue is always created and a warning is printed if attachment fails.

### FEATURE: Plan file path now shown in non-VS Code environments (#290) (2026-05-15)
Background: The plan file preview relied on CLAUDE_CODE_ENTRYPOINT, an unofficial internal variable, to detect VS Code. This caused the code -r spawn to not work reliably in CLI or other terminal environments.
Changes: VS Code detection now uses the standard TERM_PROGRAM=vscode environment variable. In non-VS Code environments (plain CLI, other terminals), the plan file path is surfaced via the systemMessage only — no code spawn is attempted.

### FEATURE: backfill-commit-comments.sh now posts human-readable 'Resolved by commit' and uses git-log fallback (#300) (2026-05-15)
Background: Issues closed via 'closes #N' PR keyword or web UI bypassed /issue-close and were missing the human-readable 'Resolved by commit' comment and the machine-readable sentinel that the standard close workflow posts.
Changes: backfill-commit-comments.sh now posts both a human-readable 'Resolved by commit HASH' comment and a sentinel for each closed issue that lacks them. Commit hashes are discovered from history.md headings first, then git log (with boundary-safe grep to prevent issue number substring collisions). Issues with no discoverable hash get a sentinel-only comment. New --canary flag posts to one issue per class first so you can verify the output on GitHub before running the full batch. Re-running is safe — already-backfilled issues are skipped automatically.

### FEATURE: Session title now shows the linked issue number and title in VS Code sidebar (#299) (2026-05-15)
Background: The Claude Code VS Code extension always showed a generic auto-generated session title — there was no way to tell which task a session was working on at a glance.
Changes: When you run /workflow-init with a GitHub issue number, or complete /clarify-intent, the VS Code sidebar session title is automatically updated to "#N <issue title>". Manually renamed sessions are left unchanged.

### BUGFIX: worktree-end cleanup operations on Windows/VS Code now work correctly (2026-05-15)
Background: Four linked bugs caused worktree-end cleanup to fail on VS Code/Windows and blocked planning workflow commands from the main worktree.
Changes: The combined cd+git-worktree-remove form is now allowed when VS Code resets the Bash CWD between calls. Stash, restore, and file-restore checkout are now permitted from the main worktree once all linked worktrees have been removed. FD-to-FD output redirects (2>&1, 1>&2) are no longer misclassified as write operations. The orphan directory cleanup step uses an absolute path that remains valid after CWD resets.

### BUGFIX: backfill-commit-comments.sh: drop unsupported --paginate flag (2026-05-15)
Background: After running backfill-commit-comments.sh against the agents repo, it reported 'Backfilled: 0, Skipped: 0' even though closed issues without sentinels existed.
Changes: The script no longer passes --paginate to gh issue list (the CLI does not support it; only gh api does). Issue listing now works; the script processes closed issues as documented.

### CONFIG: Disable 1M context for skill/subagent calls (2026-05-16)
Background: Skill invocations caused frequent 'Extra usage is required for 1M context' errors because model aliases like opus and sonnet resolve to 1M-context defaults in Opus 4.7 / Sonnet 4.6, even when the main session is set to standard context.
Changes: 1M context is now disabled system-wide for all skill and subagent calls via CLAUDE_CODE_DISABLE_1M_CONTEXT=1. The session-restart error should no longer appear.

### REFACTOR: #327: survey-code/survey-history now run before the planning interview (2026-05-16)
Background: Code survey and history review previously ran only after clarify-intent completed, so CC could not catch wrong premises during the interview.
Changes: workflow-init now launches both survey agents in parallel (all workflow paths) before the clarify-intent interview begins. CC has codebase context and git history available throughout the interview, enabling earlier detection of already-fixed issues or contradicted assumptions.

### FEATURE: Scan private-info blocklist in gh issue and PR write commands (2026-05-22)
Background: The private-info scanner previously only checked git commit messages and file edits.
Changes: The PreToolUse hook now scans --body, --title, and --body-file content when Claude runs gh issue create/edit/comment, gh pr create/edit/comment/review, or similar forge write commands. Hard blocklist hits are blocked immediately; soft (warn:) hits ask you to confirm. Private repos are still skipped.

### CONFIG: plan artifact display: remove VS Code auto-open, suppress diff when CONFIRM_*=off (2026-05-22)
Background: CONFIRM_DETAIL/OUTLINE/INTENT=off now also suppresses the show-diff.js inline preview for the corresponding artifact. VS Code auto-open (code -r) removed; the inline diff and breadcrumb are the only remaining UX.
Changes: (1) VS Code tabs no longer open for plan files. (2) show-diff.js skips the diff preview for plan artifacts when the corresponding CONFIRM_* flag is off. Breadcrumb ("Plan file written: ...") still emitted in all modes.

### FEATURE: bootstrap-labels.sh: new CLI for label setup in target repos (2026-05-23)
Background: /migrate-repo Step 1 had inline label setup logic; no standalone CLI existed for bootstrapping label management in target repos.
Changes: New bin/github-issues/bootstrap-labels.sh installs label management files (.github/labels.yml, bin/github-issues/sync-labels.sh, .github/workflows/sync-labels.yml) into a target repo (idempotent — pre-existing files are preserved) and runs the initial label sync. /migrate-repo Step 1 now delegates to this command. The migration commit allowlist is extended to include the new sync-labels artifacts so they ship into target repos.

### FEATURE: backfill-commit-comments: auto-detect bulk-import commits in Tier 1.5 (2026-05-23)
Background: Tier 1.5 hash discovery used a hardcoded commit-hash blacklist to skip bulk-import commits, requiring manual list maintenance whenever a new bulk import was detected.
Changes: Replace the hardcoded blacklist with automatic detection. Each candidate commit is inspected by counting the number of new history-entry headings it adds to docs/history.md; commits at or above TIER15_BULK_THRESHOLD (default: 3) are rejected as bulk imports and discovery falls through to the next tier. The threshold is configurable via the TIER15_BULK_THRESHOLD environment variable.

### FEATURE: Session-scoped WORKFLOW_OFF/ON sentinels (2026-05-23)
Background: Bypassing workflow enforcement for trivial edits required editing global config.
Changes: New per-session sentinels `<<WORKFLOW_ENFORCE_WORKFLOW_OFF: <reason>>>` / `<<WORKFLOW_ENFORCE_WORKFLOW_ON: <reason>>>` toggle workflow enforcement for the current session only. Bypasses block-dotenv, scan-outbound, workflow-gate, enforce-issue-close, and enforce-worktree. `enforce-system-ops` is NEVER bypassed. Subsumes `WORKTREE_OFF`.

### FEATURE: clarify-intent: tracking-issue guard prevents completion with empty closes_issues (2026-05-23)
Background: When /clarify-intent Completion reached with closes_issues empty (Path C), the workflow could emit WORKFLOW_CLARIFY_INTENT_COMPLETE without creating a tracking issue first. Also, the dual /make-outline-plan invocation (Procedure Step 6 + Completion) caused the skill to exit at Step 6, never reaching Completion.
Changes: A new guard script (check-closes-issues-nonempty.sh, backed by parse-closes-issues.js SSOT) blocks the completion sentinel when closes_issues is empty. First failure auto-invokes /issue-create and re-checks; second failure escalates to AskUserQuestion (3 options: retry, manual recovery, abort). Procedure Step 6 no longer invokes /make-outline-plan — the skill now exits exclusively via Completion.

### FEATURE: PR #483 (2026-05-23)
Background: fix(install): add launchers for review-loop-cap-menu, review-skill-size, extract-accepted-tradeoffs (#471)
Changes: Fixed: bare invocation of review-loop-cap-menu, review-skill-size, and extract-accepted-tradeoffs (exit 127) — installers now generate PATH launchers for these tools.

### FEATURE: PR #487 (2026-05-23)
Background: feat(#468): /resume-session skill; remove /boost
Changes: Added: `/resume-session` — resume a mid-workflow session by detecting the `in_progress` step and dispatching to the matching skill, or surfacing the pending worktree-end cleanup marker.;Removed: `/boost` — superseded by native VS Code + Claude Code model switching.

### FEATURE: PR #490 (2026-05-23)
Background: fix(#486): restore code --folder-uri plan-file open; fix #291 multi-window routing
Changes: Fixed: plan files (intent/outline/detail.md) now open automatically in the correct VS Code window when `CONFIRM_*=on` — restored after PR #454 had removed the auto-open unconditionally (#486). Multi-window routing fixed via `--folder-uri` workspace targeting; the file now opens in the VS Code window whose workspace matches the originating session (#291).

### FEATURE: PR #491 (2026-05-23)
Background: fix(#484): workflow-gate recognizes WORKTREE_NOTES.md as docs evidence
Changes: Fixed: docs gate が ENFORCE_WORKTREE=on 下で /update-docs → WORKTREE_NOTES.md にステージされた bullet を証拠として受理するようになった。installer-only / code-only 修正での workflow blocker (#484) を解消。

### FEATURE: PR #496 (2026-05-23)
Background: fix(#488): create-project.sh calls linkProjectV2ToRepository after board creation
Changes: Fixed: Projects v2 boards created by `/migrate-repo` are now automatically linked to the target repository — boards appear on the repo `/projects` page immediately after migration. Added `backfill-project-link.sh` to re-link existing boards created before this fix.

### FEATURE: PR #498 (2026-05-23)
Background: feat(#444): N issues per session — SSOT session model + multi-N routing
Changes: Workflow sessions now support N issues per session (N >= 1): `/workflow-init` accepts multiple `#N` references, asks which is the primary, and all listed issues are closed in the same PR

### FEATURE: PR #500 (2026-05-23)
Background: feat(#485): granular plan-skip sentinels OUTLINE_NOT_NEEDED / DETAIL_NOT_NEEDED
Changes: New: `WORKFLOW_OUTLINE_NOT_NEEDED` and `WORKFLOW_DETAIL_NOT_NEEDED` sentinels replace `WORKFLOW_PLAN_NOT_NEEDED` — plan-step skip is now granular per stage. Set `CONFIRM_OUTLINE=off` or `CONFIRM_DETAIL=off` in agents config to auto-approve the respective skip without a permission dialog.

### FEATURE: PR #499 (2026-05-23)
Background: feat(#296): retire phase-1 deferred-cleanup; add /sweep + /sweep-worktrees
Changes: `/worktree-end` no longer requires a VS Code "Reload Window" or session restart when Windows CWD lock prevents worktree directory removal. The step now completes normally; the residual directory, its branch, and any `pending-branch-delete-` marker are reclaimed automatically by the new `/sweep-worktrees` skill.;`/sweep` and `/sweep-worktrees` are new user-invocable skills for manual or scheduled cleanup of zombie worktrees and deferred branch deletions. A nightly cron runs automatically via GitHub Actions.;Existing `pending-cwd-unlock-*` markers from pre-upgrade sessions are inert and safe to delete manually from `~/.workflow-plans/worktree-end/`.

### FEATURE: PR #505 (2026-05-23)
Background: skills: stage-1 context:fork + user-invocable:false
Changes: The workflow-internal skills write-tests, write-code, run-tests, and update-docs are now hidden from the / command menu (user-invocable: false). When CLAUDE_CODE_FORK_SUBAGENT=1 is set, 12 skills run in a forked context (context: fork), reducing main conversation context window pressure.

### FEATURE: PR #507 (2026-05-24)
Background: fix(workflow): survey artifact write failure & post-check content validation (#497)
Changes: "Fix: survey agent validation now checks for the `## Verified Claims` section instead of file existence only; empty or stub artifacts trigger survey re-invocation. Survey agents are now explicitly instructed that writing their artifact is required. Closes #497."

### FEATURE: PR #509 (2026-05-24)
Background: fix(#506): show-plan-link two-step spawn + URI encoding (#492, #291)
Changes: BUGFIX show-plan-link: --folder-uri regression fix — plan files (intent/outline/detail.md) now open as VS Code tabs again when CONFIRM_*=on. The broken --folder-uri + -r combination is replaced with two sequential code invocations; folder URI encoding is also fixed for paths with spaces, #, %, non-ASCII, or UNC segments.

### FEATURE: PR #510 (2026-05-24)
Background: fix(bash-write-patterns): posix-redir kind for redirect/tee; fix 2>/dev/null inside $(...) (#460, #359)
Changes: Fix: `grep -nE "pattern > match" file.txt` のように引数内に `>` を含むコマンドが main worktree から誤って block されなくなった (#460)。`$(cmd 2>/dev/null)` など command substitution 内の `2>/dev/null` が正しく read 判定されるようになった (#359)。

### FEATURE: PR #511 (2026-05-24)
Background: feat(workflow): extend WIP fingerprint to all closes_issues (#508)
Changes: **WIP conflict detection now covers all issues in a session.** When a session tracks multiple issues, each issue receives its own WIP fingerprint. Conflict detection at session start enumerates all conflicting issues in a single prompt, and confirming Continue claims WIP for all issues at once.

### FEATURE: PR #512 (2026-05-24)
Background: fix(workflow): suppress unnecessary pauses in planning/writing pipeline
Changes: category: BUGFIX;category: FEATURE;category: FEATURE

### FEATURE: PR #517 (2026-05-24)
Background: fix(worktree-end): resolve Step 7 Final Report env loss and silent fallback on Windows (#504)
Changes: fix(worktree-end): Step 7 Final Report now reliably displays after long Step 5.5→7 env var loss on Windows; sentinel detection prevents silent fallback to hand-written Markdown (#504)

### FEATURE: PR #522 (2026-05-24)
Background: fix(workflow-mark): hard-block session-scoped sentinels on null sessionId; add transcript_path fallback
Changes: Session-scoped enforcement overrides (`ENFORCE_WORKTREE_OFF`/`ON`, `ENFORCE_WORKFLOW_OFF`/`ON`) now report an explicit error (exit 2) instead of silently doing nothing when the session ID cannot be resolved. In VS Code on Windows where `CLAUDE_ENV_FILE` is sometimes empty, the session ID is now derived from `transcript_path` so the override applies correctly.

### FEATURE: PR #520 (2026-05-25)
Background: refactor(#503): retire pending-branch-delete marker; direct worktree-list check
Changes: `/worktree-end` branch deletion no longer depends on the `pending-branch-delete` marker file — `enforce-worktree` consults `git worktree list` directly. Force-delete is restricted to feature-branch naming conventions (`feature/`, `fix/`, `refactor/`, `docs/`, `chore/`), so accidental force-delete of `main` / `master` / `release/*` is blocked at the hook layer. `/sweep-worktrees` orphan-directory reclamation now requires a `Main repo:` ownership proof in `WORKTREE_NOTES.md`; legacy worktrees created before this field will be skipped (`repo_mismatch`) and must be cleaned up manually — see the `## Migration notes for #503` section in `skills/sweep-worktrees/SKILL.md`.

### FEATURE: PR #523 (2026-05-25)
Background: fix(subagent): grant Write tool to plan-pipeline agents (#516)
Changes: Plan-pipeline subagents (survey-code, survey-history, detail-planner, outline-planner) now receive the Write tool in their front-matter grant so artifact output uses Write instead of Bash heredoc (which enforce-worktree.js blocked).

### FEATURE: PR #531 (2026-05-25)
Background: feat(workflow): flip mid-workflow finding capture to /issue-create primary; add Mid-workflow gate (#521)
Changes: Mid-workflow bug/task findings can now be filed immediately via `/issue-create` from the linked worktree. The previous WORKTREE_NOTES.md-first design (a leftover from when `gh issue create` was blocked from linked worktrees) has been corrected. `WORKTREE_NOTES.md` remains available as a fallback for non-interactive sessions, non-GitHub remotes, and explicit deferrals. `/issue-create` now surfaces a notice when called mid-workflow, reminding you the new issue will not be added to the current session's `closes_issues`.

### FEATURE: PR #533 (2026-05-25)
Background: feat(#518): multi-category post-merge actions block in Final Report
Changes: FEATURE: worktree-end Final Report now shows all post-merge required actions — Claude Code restart, VS Code reload, installer rerun, OS reboot — in a structured always-on block. Previously only Claude Code restart was shown, and the section was silently omitted in some sessions. (#518)

### FEATURE: PR #535 (2026-05-25)
Background: feat(#254,#252): unified credential hook covering 18 families; shared path-match.js helpers
Changes: SECURITY: Credential protection expanded to 18 families (2026-05-25) | Background: The credential-blocking hook previously covered only SSH keys. | Changes: New block-credentials.js now blocks access to AWS, Azure, GnuPG, GitHub CLI, Docker, Kubernetes, npm, PyPI, RubyGems, netrc, PostgreSQL, MySQL, curl, Maven, Gradle, and Terraform credentials in addition to SSH. WORKFLOW_OFF sessions remain blocked — credentials are never bypassed. Settings.json deny rules consolidated into the hook.

### FEATURE: PR #540 (2026-05-25)
Background: fix(#529): unify Projects v2 board title to <repo> — Issue Timeline
Changes: Migration workflow now creates Projects v2 boards with `<repo> — Issue Timeline` title format consistently across all repos (previously new repos received `<repo> migration` title).

### FEATURE: PR #532 (2026-05-25)
Background: fix(#519): add JSONL transcript scan fallback for session-id resolution
Changes: BUGFIX: WIP conflict detection (wip-state.sh) no longer silently fails when CLAUDE_SESSION_ID is unavailable in Bash subprocesses (VS Code / Windows). A JSONL transcript scan now reliably resolves the session ID so WIP fingerprinting and conflict alerts work correctly.

### FEATURE: PR #547 (2026-05-25)
Background: feat(#528): add WORKTREE_NOTES.md language enforcement via PostToolUse hook
Changes: WORKTREE_NOTES.md history/changelog entries are now machine-checked for language compliance on every save; language policy is driven by the docs-lang block in language.md (DOCS_LANG_HISTORY, DOCS_LANG_CHANGELOG_PUBLIC, DOCS_LANG_CHANGELOG_PRIVATE); violations are blocked with a descriptive error; policy defaults to permissive (any) if language.md is absent

### FEATURE: PR #551 (2026-05-25)
Background: feat(#524): structural enforcement of confirm-plan Step 2 path-emission rule
Changes: category: FEATURE | subject: feat(#524): confirm-plan path-emission guard via Stop hook (Gap 1) | background: When CONFIRM_<STEP>=on, a new Stop hook (stop-confirm-plan-guard.js) now blocks turns where the orchestrator emits any representation of the ~/.workflow-plans/ path in the assistant message. | changes: Previously prompt-only enforcement — structural hook guard added so violations are blocked at the hook layer before the response is delivered.

### FEATURE: PR #560 (2026-05-26)
Background: fix(#550): honor WORKFLOW_OFF/WORKTREE_OFF session markers in hooks/pre-commit
Changes: BUGFIX: WORKFLOW_OFF and WORKTREE_OFF session-scoped overrides now also bypass the hooks/pre-commit worktree-isolation gate. Previously the bypass stopped at the PreToolUse layer; git commits from the main worktree were still blocked even during an approved workflow bypass session.

### FEATURE: PR #561 (2026-05-26)
Background: fix(#277): resolve rebase/merge conflicts on history.md and CHANGELOG.md via merge=union
Changes: FEATURE | doc-append merge conflicts on history.md / CHANGELOG.md auto-resolved (#277) | Background: Parallel branches appending to docs/history.md or CHANGELOG.md previously required manual conflict resolution on every rebase or merge. | Changes: Two concurrent worktree-end runs now complete cleanly — git rebase and git merge no longer produce UU conflicts on these append-only log files. Date-ascending order is preserved automatically.

### FEATURE: PR #567 (2026-05-26)
Background: feat(#534): Stop hook — verify Post-Merge Actions Required block in Final Report
Changes: FEATURE | The `### Post-Merge Actions Required` block is now structurally enforced at worktree-end Final Report completion. A new Stop hook (`stop-final-report-guard.js`) blocks the turn if the block is missing or incomplete, and forces re-emission with the correct content rebuilt from the env-file.

### FEATURE: PR #568 (2026-05-26)
Background: feat(#548): Projects v2 parity and ## Issues section for multi-N sessions (#568)
Changes: FEATURE | Multi-N sessions: related issues now reliably receive Projects v2 board cards with Content Date; intent.md now lists all tracked issues by number and title under ## Issues instead of the primary-only ## Issue section.

### FEATURE: PR #565 (2026-05-26)
Background: fix(#334): eliminate false-positives via shared command-head helper
Changes: Fixed: hooks no longer block commands where "doc-append" or "gh issue close" appears inside quoted arguments of other commands (e.g. gh issue comment --body "see doc-append for details").

### FEATURE: PR #572 (2026-05-26)
Background: feat(#553+#470): pass survey artifacts to codex review; extract context builder to bin/
Changes: FEATURE: Codex review now receives survey-code and survey-history artifacts as context, enabling verification of planner code-research claims. The context builder (bin/build-codex-context) is now a deterministic shell script — the outline section is no longer silently dropped between planning stages.

### FEATURE: PR #575 (2026-05-26)
Background: fix(#571): update-docs reads docs-lang before proposing entries
Changes: `/update-docs` now reads the `docs-lang` config in `rules/language.md` before proposing History/Changelog entries, preventing drafts in the wrong language from reaching the user for review.

### FEATURE: PR #584 (2026-05-27)
Background: fix(#573): add extractRmTargets so Bash rm of non-repo paths is allowed
Changes: Bash `rm` of non-repo paths (e.g. `~/.claude/projects/*/memory/`) from the main worktree is no longer blocked by `enforce-worktree`. This fixes the asymmetry where the Write tool could create memory files but Bash rm could not delete them without WORKFLOW_OFF escalation.

### FEATURE: PR #586 (2026-05-27)
Background: feat(#534): schema SSOT + full-section Final Report hook validation
Changes: FEATURE | Final Report: the Stop hook now validates all 8 sections (not just Post-Merge Actions), blocking any turn where a heading is missing from the last assistant message. Renderer is backed by a shared schema SSOT (hooks/lib/final-report-schema.js); SKILL.md now contains explicit verbatim output requirements.
