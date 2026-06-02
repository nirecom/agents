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
