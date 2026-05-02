# History (agents)

## Archived
- [2026](history/2026.md) — 82 entries

### BUGFIX: Fix HIGH findings in review-code-codex from Codex self-review (2026-04-27, pending)

Background: Running review-code-codex on its own diff revealed three HIGH-severity issues: (1) --base without argument caused unbound-variable crash before emitting status line, violating output contract; (2) git diff failures were silently treated as empty diff (SKIPPED) instead of FAILED, creating false coverage; (3) prompt was passed as command-line argument instead of stdin, risking OS arg length limits on large diffs. Also: PATH-filtering approach in tests broke once codex was actually installed (fnm path not filtered).

Changes: bin/review-code-codex: check $# before accessing $2 for --base; capture git diff stderr and emit FAILED on non-zero exit; pass prompt via stdin ('-') instead of command-line arg. tests/feature-review-code-codex.sh: add cases for --base-missing-arg and git-diff-fail; replace PATH-filtering with MINIMAL_PATH=/usr/local/bin:/usr/bin:/bin to reliably hide codex without removing bash/git.

### CONFIG: installer: gray color for already-done messages on Linux/WSL (2026-04-28, pending)

Background: On Windows, already-handled items use Write-Host -ForegroundColor DarkGray. On Linux/WSL, these were plain white echo — making re-runs harder to scan.

Changes: install.sh: added C_GRAY to color block, exported all color vars for child script inheritance. dotfileslink.sh: Symlinks created/core.hooksPath/Generated in green, backups in yellow. claude-code.sh and codex.sh: already installed in gray, installed in green. session-sync-init.sh: already exists in gray, initialized in green, Remote set to unchanged. Profile sourcing messages in green. check-cross-platform.js error message updated to specify --short hash.


### FEATURE: Worktree safety: rules, skills, and deny hardening (2026-04-28, pending)
Background: INCIDENT #2 (worktree deletion silently destroyed a gitignored dotenv file, making Langfuse volume passwords unrecoverable) revealed no skill-based procedure existed for worktree entry/exit. This adds structured guardrails: a rule for when to use worktrees, two skills encapsulating the entry/exit procedure, URL-safe secret generation guidance, and a risky-operations decision path requiring recovery options before destructive proposals.
Changes: Added rules/worktree.md (skill-only entry/exit policy + fit criteria; skill notice moved to top). Added skills/worktree-start (worktree setup + gitignored file classification and copy). Added skills/worktree-end (inventory, backup manifest, Docker bind-mount detection, dry-run summary, and safe removal). Added skills/create-key (URL-safe password generation: hex / base64url / percent-encode; opaque secret guidance; handling and storage rules). Added rules/ops.md (Risky Operations Decision Path: enumerate recovery options before any destructive command). Added two deny entries to settings.json blocking Remove-Item -Recurse -Force (both arg orders).

### FEATURE: Codex-first plan review: integrate Codex as primary plan reviewer (2026-04-28, pending)
Background: review-code-codex at Step 5 showed good results. Manually feeding plan-mode output to Codex surfaced different perspectives from Claude reviewer. Goal: integrate Codex as the primary reviewer in make-detail-plan and design-approach loops to improve plan quality and load-balance Claude token costs.
Changes: Added bin/lib/codex-core.sh: shared library (codex_core_init, codex_core_adversarial_preamble, codex_core_check_cli, codex_core_run, codex_core_log, codex_core_emit_failed). Added bin/review-plan-codex: CLI with --input <file> --format {detail-plan|approach}; emits Codex Plan Review: PERFORMED/SKIPPED/FAILED; always exits 0. Refactored bin/review-code-codex to source codex-core.sh (public interface unchanged); added adversarial preamble to prompt. Updated skills/make-detail-plan and skills/design-approach to codex-first review loop each round; fall back to Claude reviewer subagent on SKIPPED/FAILED/malformed with explicit user-visible message. Added fallback-role notes to agents/reviewer.md and agents/approach-reviewer.md. Added review-plan-codex launchers to install/linux and install/win. Added tests/feature-review-plan-codex.sh (22 cases); added preamble assertion to feature-review-code-codex.sh. Fixed symlink source path bug in both bin scripts (dirname realpath).

### BUGFIX: workflow-gate: auto-detect repo via additionalDirectories (2026-04-28, pending)
Background: When git commit ran without -C from a dotfiles-primary session, resolveRepoDir used CLAUDE_PROJECT_DIR (dotfiles), so evidence checks looked for staged tests/docs in the wrong repo.
Changes: resolveRepoDir now checks CLAUDE_PROJECT_DIR for staged changes first; if none, scans additionalDirectories from settings.json via __dirname. Falls back when nothing is staged. Fixed stale path in fix-workflow-gate-unix-path.sh; added H1-H3 detection tests.

### REFACTOR: Rename design-approach to make-outline-plan (2026-04-28, pending)
Background: The design-approach skill name caused confusion with UI design work and lacked symmetry with make-detail-plan. Renaming to make-outline-plan (outline vs detail) makes the pairing clear.
Changes: Renamed skill design-approach to make-outline-plan (directory + SKILL.md), subagents approach-designer to outline-planner and approach-reviewer to outline-reviewer, completion marker WORKFLOW_DESIGN_APPROACH_COMPLETE to WORKFLOW_OUTLINE_PLAN_COMPLETE, and test feature-design-approach.sh to feature-make-outline-plan.sh. The --format approach CLI flag and <session-id>-approach.md output filename were left unchanged (internal artifact labels). Updated 17 files across agents and dotfiles-private repos.

### FEATURE: Add next-step transition hints to SessionStart and workflow-mark (2026-04-28, pending)
Background: SessionStart and workflow-mark only emitted session_id in additionalContext, so when users gave instructions without naming a skill (e.g. 'start langchain phase 5'), Claude would skip clarify-intent and jump straight to implementation. The only enforcement point was the commit-time workflow-gate.js with no guidance during the session.
Changes: hooks/lib/workflow-state.js: added NEXT_STEP_HINT table (step to next-skill instruction string) and nextStepHint(step) function, both exported. hooks/session-start.js: added buildWorkflowStatus() that outputs all 9 step statuses and a NEXT ACTION line in additionalContext on every SessionStart. hooks/workflow-mark.js: after each successful markStep() call in all sentinel handlers, appends nextStepHint() result to additionalContext as a transition hint. 8 SKILL.md files (clarify-intent, make-outline-plan, make-detail-plan, survey-code, deep-research, write-tests, review-code-security, update-docs): Completion sections converted to numbered lists with explicit next-skill Skill tool invocation step after the sentinel echo. tests/feature-workflow-transition-hint.sh: 19 test cases (SS-1 to SS-4, WM-5 to WM-12).

### FEATURE: session-sync: sync plans/ across machines (2026-04-29, (pending))
Background: Plan files written to ~/.claude/plans/ (e.g. *-intent.md generated by clarify-intent, make-outline-plan, make-detail-plan) were not included in session-sync. When continuing work on another machine, previously created plan files were unavailable.
Changes: Added plans sync to push/pull/reset in bin/session-sync.sh and bin/session-sync.ps1. Push: copies $CLAUDE_DIR/plans/ into $PROJECTS_DIR/plans/ before git add. Pull/reset: copies files from $PROJECTS_DIR/plans/ into $CLAUDE_DIR/plans/ (merge — local-only files are preserved). Skips silently when plans/ is absent on either side. Added 10 assertions (8 test cases) to tests/main-session-sync.sh and 4 Pester tests to tests/main-session-sync.Tests.ps1. All new plans tests pass.

### REFACTOR: Subagent model/effort optimization + planner rename + outline.md unification (2026-04-29, pending)
Background: Token consumption was reaching 80-100% of Opus session budget in a single workflow run. Community research (wshobson/agents, VoltAgent, davepoon) confirmed the industry pattern: Opus for critical review only, Sonnet for standard work, effort:high reserved for heavy decision-making roles (doctor/triage equivalents). This refactor aligns agent configuration with that practice.
Changes: model: sonnet — clarify-intent, make-outline-plan (orch), make-detail-plan (orch), detail-planner (ex planner), write-tests. model: opus / effort removed — outline-planner, outline-reviewer. model: opus / effort:high kept — detail-reviewer (ex reviewer). model: opus / effort:high added — review-code-security (security audit is the heaviest decision). effort:low removed — survey-code, update-docs. Progressive disclosure added to outline-planner and detail-planner: start with docs/architecture.md + docs/todo.md, Grep before Read, max 8 source files, do not re-read rules/ (already in system prompt). Renamed planner.md -> detail-planner.md and reviewer.md -> detail-reviewer.md for explicit role distinction. Renamed session artifact approach.md -> outline.md throughout. Split clarify-intent output into intent.md (Background/Scope/Constraints only, passed downstream) and intent-log.md (Q&A transcript, not passed downstream) to reduce context copied into each subagent prompt.

### FEATURE: document plan mode incompatibility (2026-04-29, pending)
Background: Plan mode restricts Skill tool invocations, causing the mandatory workflow to be silently skipped. A SessionStart hook approach was investigated but hook additionalContext is not surfaced to Claude in plan mode, making it ineffective.
Changes: Added plan mode incompatibility notes to README.md (before Docs-only short-circuit bullet) and CLAUDE.md (new section before Docs-only Short-circuit).

### BUGFIX: Fix cleanup STEP_HINT sentinel format (2026-04-29, pending)
Background: STEP_HINT for cleanup used ':main' suffix in the sentinel, not matched by workflow-mark.js regex (WORKFLOW_MARK_STEP_cleanup_skipped: main).
Changes: Corrected to echo '<<WORKFLOW_MARK_STEP_cleanup_skipped>>' without suffix.

### FEATURE: Add show-diff.js: display-only PreToolUse hook for code diffs (2026-04-29, pending)
Background: require-diff-approval.js was a blocking PreToolUse hook requiring /tmp/diff-approved-<HASH> token files before each Edit/Write. It was never registered in settings.json so diff display never worked, causing frequent incidents where code changes were made without showing diffs in chat.
Changes: Replaced require-diff-approval.js with show-diff.js: a display-only PreToolUse hook that outputs systemMessage with diff preview (no decision field, no blocking). Registered in ~/.claude/settings.json PreToolUse with timeout 10.

### BUGFIX: fix: suppress create/delete mode output in session-sync on macOS (BSD grep compat) (2026-04-29)
Background: macOS (BSD grep) does not support \s in ERE mode (-E flag). The pull action filter '^\s*(create|delete) mode ' used grep -Ev which silently failed to match on macOS, letting all create/delete mode lines through. Additionally, git commit -q on macOS can still emit create/delete mode lines to stdout when new files are staged.
Changes: bin/session-sync.sh pull: replaced \s with [[:space:]] (POSIX character class, works on both BSD and GNU grep). bin/session-sync.sh push: added >/dev/null to initial commit to suppress stdout create/delete mode output on macOS git.

### BUGFIX: session-sync push failure on UD conflict + hooksPath always applied (2026-04-29, pending)
Background: session-sync push failed silently after 3 retries when rebase encountered a delete/modify conflict (file deleted by remote, still present locally). The case block only handled *.jsonl, leaving *.json workflow files unresolved → rebase --abort → push failure. Separately, session-sync-init only set core.hooksPath=/dev/null at first git init; if agents was reinstalled (writing ~/.gitconfig) without re-running session-sync-init, the projects repo inherited the agents hooks and blocked rebase --continue commits.
Changes: bin/session-sync.sh: added *) catch-all to conflict case (git rm to accept remote deletion); rebase --continue now falls back to rebase --abort on failure. install/linux/session-sync-init.sh and install/win/session-sync-init.ps1: moved core.hooksPath setting outside the init-only block so it is always applied on every run.

### CONFIG: settings: fix Write allow glob for intent-log.md (2026-04-29, pending)
Background: Added a Write allow rule to settings.json to suppress the permission dialog when clarify-intent writes intent-log.md. The initial pattern ~/.claude/plans/*-intent-log.md did not match because tilde is not expanded to the full absolute path at match time.
Changes: Changed allow rule to Write(**/.claude/plans/*-intent-log.md) so it matches the full absolute path.

### CONFIG: Move personal WebFetch domains to settings.local.json (2026-04-29, pending)
Background: Some WebFetch domains in the settings.json allow list were personal-workflow-specific or framework-specific and not appropriate to keep in a public repo.
Changes: Removed WebFetch(domain:ecc.tools), WebFetch(domain:langfuse.com), WebFetch(domain:docs.langchain.com), and WebFetch(domain:reference.langchain.com) from settings.json. These four entries are moved to settings.local.json (gitignored), whose source file lives in dotfiles-private and is deployed via dotfileslink symlink.

### CONFIG: settings: cover both intent-log.md filename formats in allow pattern (2026-04-29, pending)
Background: Two filename formats exist for intent-log.md: UUID-based sessions produce <uuid>-intent-log.md, while the timestamp fallback produces intent-YYYYMMDD-HHMMSS-log.md. The previous fix (intent-*-log.md only) missed the UUID format.
Changes: Added both Write(**/.claude/plans/*-intent-log.md) and Write(**/.claude/plans/intent-*-log.md) to cover both filename formats.

### FEATURE: installer platform guards for install.sh/install.ps1 (2026-05-01, pending)
Background: install.sh had no guard against running in Git Bash/MSYS2/Cygwin on Windows. install.ps1 had no guard against running on Linux/macOS via PowerShell Core 7+.
Changes: install.sh: added uname -s check blocking MINGW*/MSYS*/CYGWIN* with printf %s format injection safety, placed before AGENTS_ROOT setup. install.ps1: added $IsWindows -eq $false guard before Set-StrictMode. Profile sourcing already-present message changed Green to DarkGray in both scripts.

### BUGFIX: installer idempotency: gray display for already-done operations (2026-05-01, pending)
Background: Second run of install.ps1 triggered unnecessary secret injection (the secrets CLI ran even when the injected output file already existed in dotfiles-private), showed incorrect symlink backup warnings (path comparison used raw Target string without normalization), always set core.hooksPath green, always regenerated launcher files green, always showed Session sync initialized green, and always wrote VS Code settings even when unchanged.
Changes: dotfileslink.ps1: added Write-Launcher helper for idempotent launcher writes (DarkGray if unchanged); fixed symlink path comparison with GetFullPath() normalization; added current-value check for core.hooksPath (DarkGray if unchanged). session-sync-init.ps1: added _changed tracking, remote URL check before set-url, DarkGray already-up-to-date message when no-op. vscode-settings.ps1: compare each patch key before writing; skip write and backup when all keys already match. session-sync-init.sh: same idempotency fixes as PS version.

### BUGFIX: doc-append: initialize tail_text to suppress Pylance possibly-unbound warning (2026-05-01, pending)
Background: tail_text was assigned inside a for loop, so Pylance flagged it as possibly unbound at usage on line 152.
Changes: Added tail_text = "" initializer before the loop.

### FEATURE: Add repo-visibility tool for gh-based public/private detection (2026-05-01, pending)
Background: Needed a reliable way to check repo visibility (public/private) from Claude Code without per-repo CLAUDE.md maintenance. Direct gh command failed due to MSYS2 path mangling and lack of -C flag support in gh.
Changes: Added bin/repo-visibility.py: accepts Windows (c:/git/...) or WSL (/mnt/<drive>/...) path formats, normalizes per platform, runs gh repo view to output 'public' or 'private'. Added launchers in dotfileslink.sh (bash wrapper) and dotfileslink.ps1 (.cmd wrapper). Language policy updated in dotfiles-private rules/language.md to use repo-visibility command.

### FEATURE: Assemble ~/.claude/settings.json from base + private extension (2026-05-02, pending)
Background: hooks (e.g. fornix-agent) require entries in settings.json but settings.json was a public-repo symlink, leaking private paths. settings.local.json does not support hooks. Solution: replace the symlink with an assembled real file. agents/settings.json stays public (base); agents/settings-extension.json (gitignored, symlinked from dotfiles-private) holds private additions. assemble-settings.js performs schema-aware merge (hooks/permissions arrays concatenated; env/attribution object-merged; other keys extension-overrides base) and writes ~/.claude/settings.json on every install.
Changes: Add install/assemble-settings.js. dotfileslink.ps1/sh: remove settings.json symlink, add stale-symlink cleanup, call assembler. workflow-gate.js: read additionalDirectories from assembled ~/.claude/settings.json with fallback. .gitignore: add settings-extension.json. dotfiles-private/install.{ps1,sh}: move agents installer to last (Step 6) so assembly runs after fornix hooks are injected into the extension file.

### FEATURE: Reset user_verification after git push; delete obsolete privacy.md (2026-05-02, pending)
Background: Once user_verification was marked complete it persisted for the rest of the session, allowing follow-up pushes without re-verification. This created a window where post-push bug fixes could be committed and pushed without user sign-off. rules/privacy.md contained obsolete .context-private/ instructions superseded by rules/private-info.md.
Changes: hooks/workflow-mark.js: hoist toolResponse/exitCode/sessionId; add push-detection block that resets user_verification to pending on successful git push; markStep failure emits FAILED message instead of silently succeeding. rules/privacy.md: deleted (obsolete).

### BUGFIX: profile-snippet.ps1: remove settings.json from symlink watchlist (2026-05-02, pending)
Background: profile-snippet.ps1 listed settings.json alongside CLAUDE.md as a symlink to monitor for breakage. However, settings.json is now an assembled file (written by assemble-settings.js), never a symlink. This caused the broken-symlink check to always fire, triggering dotfileslink.ps1 on every shell start even when nothing was broken.
Changes: Removed settings.json from the _agentSymlinks watchlist in profile-snippet.ps1. Only CLAUDE.md is now monitored.

### CONFIG: codex-core: increase review timeout 60s to 180s (2026-05-02, pending)
Background: Large plans (187+ lines) were timing out at 60s in review-plan-codex and review-code-codex. Diagnosed via ~/.claude/projects/codex-review logs — a 187-line plan hit the wall exactly at 60s.
Changes: bin/lib/codex-core.sh: changed timeout 60 to timeout 180; updated FAILED message to 'timeout (180s)'.
