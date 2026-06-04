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
