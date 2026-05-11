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
