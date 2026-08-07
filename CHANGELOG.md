## Archived
- [2026](changelog/2026.md) — 133 entries

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

### FEATURE: PR #1530 (2026-07-19)
Background: fix(#1521, #1196): write_tests evidence fallback + mark-step evidence gate
Changes: Fixed a bug where the `write_tests` step would stay pending after PR merge even though test files were already committed, causing an oracle abort in `/worktree-end`. The evidence check now looks at committed changes when the staging area is empty.;`WORKFLOW_MARK_STEP_write_tests_complete` sentinel now accepted when staged or committed test evidence exists (previously always rejected). Guides recovery with `--reset review_tests` when `review_tests` completes ahead of `write_tests`.

### FEATURE: PR #1535 (2026-07-19)
Background: fix(#1528): add TERMINAL_ALERT_PHASES constant; supervisor shim/guard closed+paused bypass
Changes: `WORKFLOW_ENFORCE_WORKTREE_OFF` sentinel no longer blocked after `session-close` completes or supervisor alert retry-exhaustion, when findings are present but cumulative severity is below `error`.

### FEATURE: PR #1538 (2026-07-19)
Background: fix(#1526): add hooks/workflow-gate/ copy and bin/scan-offensive stub to test sandboxes
Changes: Restored full test coverage for `scan-outbound.js` offensive-content detection: T1,T3,T5–T9 now pass green after sandbox setup was fixed to include missing dependencies.

### FEATURE: PR #1539 (2026-07-19)
Background: fix(#1492): PROPAGATE_LABELS_REPOS format — semicolon-separated absolute paths
Changes: `PROPAGATE_LABELS_REPOS` format changed to semicolon-separated absolute directory paths (e.g. `C:\git\dotfiles;C:\git\my-private-repo`). Space-separated `owner/repo` format no longer works. Update your `.env` before the next propagation run.

### FEATURE: PR #1549 (2026-07-19)
Background: fix(#1542): add CI fallback in propagate-labels.sh; pass PROPAGATE_LABELS_REPOS in sync-labels.yml
Changes: Labels now propagate to sibling repos in CI: the `sync-labels.yml` propagate job now receives `PROPAGATE_LABELS_REPOS`; Windows absolute paths that do not exist on ubuntu-latest are automatically resolved to `owner/repo` via repo basename and the current repo's git remote owner.

### FEATURE: PR #1547 (2026-07-19)
Background: fix(#923): normalize POSIX paths in isMainCheckout to fix worktree-remove block
Changes: `git worktree remove` no longer incorrectly blocked when Git Bash supplies a POSIX-form working directory path (e.g., `/path/to/repo`) as `toolInput.cwd`. Fix is root-cause level: `isMainCheckout` now normalizes POSIX paths before passing them to `spawnSync`, symmetric with the existing normalization in `findRepoRootForBash`.

### FEATURE: PR #1555 (2026-07-19)
Background: feat(#1537): add /resume-session hint to PostCompact notification
Changes: Context-compaction notification (PostCompact) now includes a recovery hint when the workflow is in progress: "→ Workflow is in progress. Run /resume-session to resume from the current step." The hint is suppressed after a PR merge (expected state), so it only appears when action is genuinely required.

### FEATURE: PR #1556 (2026-07-20)
Background: feat(#1544): /issue-create reopen verdict — idempotent 3-point update
Changes: `/issue-create` reopen verdict now refreshes the issue body with a **Reopened** banner (count + timestamp), maintains a single reopen-log comment via edit (no stacking), and applies the new `status:regressed` label — preventing sessions from misreading a previously-closed regression issue as "done".

### FEATURE: PR #1550 (2026-07-20)
Background: feat(#943): add per-hook seam L3 tests for 6 workflow hooks; split test taxonomy to L1-L4
Changes: Added per-hook seam TL3 tests for workflow-mark, session-start, stop-confirm-plan-guard, and stop-final-report-guard hooks: each runs a real `claude -p` session and asserts observable side effects. subagent-start and post-compact documented as TL3 gap pending a future full-pipeline TL4 suite. All tests gated by RUN_E2E.;Test-layer taxonomy is now TL1–TL4 (prefixed to stay greppable): "E2E" refers specifically to full-pipeline (workflow-init → Final Report) tests; single-hook real-session tests are TL3.

### FEATURE: PR #1559 (2026-07-20)
Background: feat(#1552): add --no-delete flag and protected: labels key to sync-labels.sh
Changes: `sync-labels.sh` now supports `--no-delete` to add and update labels without deleting any existing ones, and a `protected:` list in `.github/labels.yml` that shields GitHub default labels (bug, enhancement, etc.) from deletion during a normal sync. Set `PROPAGATE_LABELS_NO_DELETE` to propagate labels to sibling repos without deleting theirs.

### FEATURE: PR #1562 (2026-07-20)
Background: fix(#1557): audit-tests staleness via closed_at; add common orphan detector and scope tag enforcement
Changes: `bin/audit-tests.sh` now uses GitHub issue `closed_at` instead of last-commit date to detect stale issue-specific tests — fixes a regression introduced in 2026-06-01 where all candidates were suppressed.;New `/sweep-tests` skill reports retirement candidates on demand (scope:common orphan detection via `bin/audit-tests-common.sh`; nightly CI steps added).;`bin/check-test-scope-tag.sh` enforces `scope:issue-specific` / `scope:common` tag on staged `tests/*.sh` at pre-commit.

### FEATURE: PR #1570 (2026-07-20)
Background: feat(#1567,#295,#1566): self-sufficient gh + jq installer; add Prerequisites docs
Changes: The installer (`install.ps1` / `install.sh`) now automatically installs `gh` (GitHub CLI) and `jq`. On interactive runs, `gh auth login` is attempted if not already authenticated; `gh auth refresh -s project` adds the Projects v2 scope required by `/issue-create`. CI / headless environments are skipped safely.;A new **Prerequisites** section in the README lists `gh` and `jq` with their required scopes and why each is needed.

### FEATURE: PR #1577 (2026-07-20)
Background: fix(#1568 #1533 #1457 #1449 #1385 #1191): fix 6 false positives in enforce-worktree hook
Changes: Fixed 6 false positives in the `enforce-worktree` hook that blocked sanctioned commands (multi-line `gh issue create` body, ANSI-C-quoted body, `run-quality-gates.sh`, `bash -c` read-only workflow CLI, VAR-prefixed dispatch) from the main worktree.

### FEATURE: PR #1578 (2026-07-20)
Background: fix(#1560,#1546,#1262,#1545,#1548,#1565): propagate-labels PAT fallback, depth-1 scan, hooksPath clear, asset copy, docs, fixture fixes
Changes: `propagate-labels.sh` no longer requires `PROPAGATE_LABELS_PAT` — it now falls back to `gh auth token` when the variable is unset, making local developer runs work out of the box.;`PROPAGATE_LABELS_REPOS` now accepts a parent directory: every git repo found one level deep is synced, letting you point it at a whole `~/git` parent instead of listing repos individually.;`propagate-labels.sh` now propagates `sync-labels.sh` and shared `.github` templates/workflows alongside `labels.yml`, keeping sibling repos fully in sync with agents in one pass.

### FEATURE: PR #1580 (2026-07-20)
Background: fix(#1573): gh auth refresh -s project — add idempotency scope check (#1580)
Changes: Installer no longer triggers interactive device-auth prompts on re-run when GitHub project scope is already granted.

### FEATURE: PR #1585 (2026-07-20)
Background: refactor(#1581): rename RUN_E2E to RUN_TL3; fix TL3 test selection
Changes: `RUN_E2E` flag renamed to `RUN_TL3` — if you run TL3 tests locally, update your `.env` (`RUN_E2E=on` → `RUN_TL3=on`). Setting `RUN_TL3=on` now also auto-selects all `tests/TL3-*.sh` files when running the test suite via `bin/select-tests.sh`.

### FEATURE: PR #1587 (2026-07-20)
Background: fix(#1576): audit-tests parser hardening + sweep-tests --fix-headers/--apply
Changes: `audit-tests` gains `--fix-headers` (report malformed `# Tests:` tokens) and `--apply` (auto-rewrite headers; git-rm closed stale test files). `pre-commit` now enforces the `# Tests:` header format (regex `^[A-Za-z0-9._/-]+$` per token) and blocks commits that violate it. `bin/check-test-scope-tag.sh` renamed to `bin/check-test-frontmatter.sh`.
### BUGFIX: fix(#1579): issue-create label reliability improvements (2026-07-20)
Background: reporter-model:* labels were silently failing due to stale model label names in SKILL.md after PR #1496 renamed them
Changes: - `/issue-create`: `reporter-model:*` labels are now applied reliably — the LLM passes the raw model name via `--reporter-model` and the script resolves the correct label, eliminating the silent failures introduced when PR #1496 renamed `model:*` to `reporter-model:*` without updating SKILL.md.
- `/issue-create`: severity is now forced to `high` when the issue title or body contains the words `abort`, `hang`, `security`, or `leak` (word-boundary match, conservative).

### FEATURE: PR #1612 (2026-07-24)
Background: fix(#1600,#1590,#1501,#1307): finalize-worker overlay for SANCTIONED allowlist
Changes: Fixed: `/issue-close-finalize` Phase 2 no longer fails on the loop-step, run-initial, and finalize-terminal scripts — these are now recognized as sanctioned worker-script invocations.;Fixed: the issue-close-finalize meta-label fast path no longer misreads issue-body prose as an incomplete sub-issue checklist.

### FEATURE: PR #1618 (2026-07-25)
Background: feat(off-gate): reason-vetting OFF gate, emergency sentinels, next-step pause
Changes: New emergency OFF sentinels (`WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY` / `WORKFLOW_ENFORCE_WORKTREE_OFF_EMERGENCY`) let you force-exit workflow/worktree enforcement when accumulated warnings or errors would otherwise block the normal OFF switch. They bypass the Phase-1 examiner and require human approval, and every use is audited.;The normal OFF switch is now gated on a reason-bound clearance token vetted by an independent supervisor pass, not on accumulated severity: a legitimate reason passes even under accumulated errors, and an illegitimate one is rejected even with zero errors. The final emit still requires human approval.;New `NEXT_STEP_PAUSE` / `NEXT_STEP_RESUME` sentinels quiet next-step's per-turn re-announcements while you deliberately work outside the workflow.;OFF-sentinel block messages are now honest: a fresh session with no supervisor findings no longer shows a misleading "Active supervisor findings exist" message.

### FEATURE: PR #1628 (2026-07-25)
Background: feat(#1611): model-conditional prompt hardening for low-gap-filling backends
Changes: New VERBOSE_PROMPT_MODELS setting: when the running model matches the allowlist, workflow-rule reinforcement text is auto-injected at session start and after compaction (no effect for models outside the list).;Direct edits to rotated history/changelog archive files (docs/history/*.md, changelog/*.md) are now blocked, matching the existing append-only guard on history.md / CHANGELOG.md.

### FEATURE: PR #1635 (2026-07-25)
Background: fix: remove unauthorized SESSION_MODEL_ID env override
Changes: Removed the SESSION_MODEL_ID environment variable and automatic model self-report detection from prompt hardening. Model detection now relies solely on the session hook payload and the VERBOSE_PROMPT_MODELS allowlist.

### FEATURE: PR #1634 (2026-07-25)
Background: fix(#1610): worktree transition guard — ExitWorktree reminder + outside-worktree write gate
Changes: `/worktree-start` now enters the newly created worktree automatically, and `/worktree-end` releases that binding when switching back to the main worktree.;A session-stop reminder now warns when the worktree was entered but never exited, so the extension-host worktree binding is not left dangling at session end.;Edits are now blocked when a session has a linked worktree but the current working directory is outside it (after the branch/worktree step); the block message explains how to enter the worktree and lists the opt-out escape hatches.;`enforce-worktree` block messages now include clearer remediation guidance.

### FEATURE: PR #1650 (2026-07-25)
Background: fix(#1641): use paths: frontmatter key for conditional rules
Changes: Conditional `rules/` files are now actually loaded conditionally. They previously declared their scope under a frontmatter key Claude Code does not read, so all of them were injected into every session regardless of which files you were working on.

### FEATURE: PR #1664 (2026-07-28)
Background: refactor(#1569, #1630): shared quote-span scanner + env-independent AGENTS_CONFIG_DIR anchor
Changes: enforce-worktree write detection now runs on a single shared quote/expansion-span scanner, so shell quoting forms that one guard understood and another missed behave the same way everywhere; ambiguous or pathologically nested commands resolve to a block instead of slipping through.;Sanctioned finalize-worker commands are no longer falsely blocked when `AGENTS_CONFIG_DIR` is missing or stale in a subagent-spawned hook process.

### FEATURE: PR #1649 (2026-07-28)
Background: feat(#1627): add bin/vscode-patch-include-worktrees
Changes: New `bin/vscode-patch-include-worktrees` re-enables worktree sessions in the VS Code extension's session list. Sessions started from a linked git worktree were missing from the list, and each extension upgrade undid a manual fix. Run the command, then `Developer: Reload Window`; `--dry-run` reports what it would change without writing. The tool refuses instead of guessing when an extension build no longer matches the expected shape.

### FEATURE: PR #1646 (2026-07-28)
Background: fix(#1591): fail-closed outbound scan guard for gh issue/PR writes
Changes: GitHub issue/PR content created or updated mid-session (including auto-created tracking issues) is now scanned for private info before submission and blocked if the scan can't run or finds a match

### FEATURE: PR #1677 (2026-07-28)
Background: refactor(#1655): relocate vscode-cc-repair out of bin/lib/ and document apply-by-default
Changes: `bin/vscode-cc-repair` is now a directory: run it as `bin/vscode-cc-repair/index.js`. Its implementation modules moved out of `bin/lib/`, which is reserved for libraries shared by more than one entrypoint.;README now states explicitly that the tool applies for real unless `--dry-run` is passed, and that `--prune-stub-sessions` renames matched stub session files to `.bak` without asking for confirmation.

### FEATURE: PR #1675 (2026-07-28)
Background: feat(#1672): add --allow-backdate to doc-append and batch backfill script
Changes: `/issue-reconcile` can now backfill issues closed long ago. `doc-append --allow-backdate` lifts the ascending-date guard for backfill only, and a new batch script records a whole list of issues in one pass.

### FEATURE: PR #1683 (2026-07-29)
Background: feat(#1640): lightweight measurement infrastructure
Changes: Added two read-only measurement commands: `bin/measure-norm-docs`, which reports the size of normative docs against the file-split thresholds, and `bin/count-subagents`, which counts subagent invocations in a session. Added an opt-in `RECORD_STEP_TIMESTAMPS` setting (default `off`) that records when each workflow step started.

### FEATURE: PR #1700 (2026-07-29)
Background: refactor(#1586): decouple verification-gate ask from RUN_TL3; add RUN_TL4
Changes: Added a new configuration option, `RUN_TL4` (default `off`), that controls the verification confirmation prompt shown before commit or merge. `RUN_TL3` now controls only which tests are selected and run.;If you previously set `RUN_TL3=on` and relied on that confirmation prompt, it will no longer appear. Add `RUN_TL4=on` to your configuration to keep the previous behaviour.

### FEATURE: PR #1704 (2026-07-29)
Background: fix(#1679): enforce-worktree write-detection false-positive fixes
Changes: Fixed main-worktree write guard incorrectly blocking `eval "$(...)"`, `bash -c '...'` wrappers, `$(...)` command substitutions, and heredoc syntax in quoted prose arguments — all sanctioned non-file-write patterns now pass through correctly.

### FEATURE: PR #1703 (2026-07-29)
Background: feat(#1701): block HARD file-size limit in workflow-gate.js (Gate 2)
Changes: Gate 2 in `workflow-gate.js` now blocks commits when any staged code file exceeds 500 lines (HARD limit from `rules/coding/file-split.md`). The check reads the staged index blob so a commit that performs a split passes immediately.

### FEATURE: PR #1702 (2026-07-29)
Background: fix(#1305,#1681,#1091,#1619,#1648,#1674): Approach B read-time state derivation — veto de-skip, stale-state guard, early-gate security hardening
Changes: Fixed: new workflow sessions no longer inherit stale state from a prior session that was abandoned before any real work began (#1305);Fixed: workflow sessions with a vetoed speculative plan skip now correctly return to the outline or detail planning step (#1681);Fixed: workflow-gate early tier now fails closed on derivation error instead of treating all steps as complete (#1674)

### FEATURE: PR #1707 (2026-07-29)
Background: fix(#1161): next-step post-merge guard — skip user_verification when reset_reason=post-merge
Changes: bugfix: next-step no longer re-prompts for user verification after gh pr merge completes the WE-8 step

### FEATURE: PR #1708 (2026-07-29)
Background: fix(#1706): remove duplicate openInBrowser call from show-user-verified-context.js
Changes: Fixed: PR URL opened twice in the browser (once on `gh pr create`, once before the USER_VERIFIED approval dialog). Now opens exactly once via `pr-created-open.js`.

### FEATURE: PR #1711 (2026-07-30)
Background: feat(#1643): replace six LLM worker subagents with a deterministic dispatcher
Changes: Deterministic workers — test runner, worktree copy and backup, doc append, issue reconcile, and the session-close gate — now run as plain scripts through a single dispatcher instead of as LLM subagents. Same output contract for the calling skills, without spending a subagent context on work that has no judgement in it.;The pre-Final-Report gate now fails closed when the supervisor state file is unreadable: it yields for review rather than treating a corrupt file as "no findings".;Test runs dispatched from a linked worktree now run that worktree's tests. Previously the runner resolved its suite from the main worktree regardless of where it was told to run, so a branch's tests could report green without ever having been executed.;Backups taken by `/worktree-end` are now excluded from version control by the tracked ignore rules, not only by machine-local ones. A `.env` copied into a backup directory could previously be staged for commit from a different clone of the same repository.

### FEATURE: PR #1729 (2026-07-30)
Background: feat(#1721): centralize subagent parallel-dispatch protocol
Changes: Reduced redundant parallel-dispatch instructions across workflow skills by centralizing them in a shared subagent-concurrency protocol doc, and documented why a few steps must stay serial.

### FEATURE: PR #1737 (2026-07-30)
Background: fix(#1725): honor WORKFLOW_OFF / EMERGENCY OFF override in block-history-direct.js
Changes: Fixed: `block-history-direct.js` now respects an active `WORKFLOW_ENFORCE_WORKFLOW_OFF` / `WORKFLOW_ENFORCE_WORKFLOW_OFF_EMERGENCY` session override instead of always blocking append-only doc writes.

### FEATURE: PR #1752 (2026-07-31)
Background: fix(#1734): route plan-truncation warning to stderr, not stdout
Changes: Fixed a bug where an oversized plan/draft (over 5000 lines) passed to the Codex plan-review loop could incorrectly halt the review with an "unrecognized status header" error instead of proceeding normally.

### FEATURE: PR #1751 (2026-07-31)
Background: fix(#1068): exclude staged deletions from compute-staged-tests-token fingerprint
Changes: Fixed `/review-tests` COMPLETE sentinel incorrectly blocking when staged test changes included deletions.

### FEATURE: PR #1772 (2026-07-31)
Background: feat(#1743): add /wf-init alias for /workflow-init
Changes: Added `/wf-init` as a short alias for `/workflow-init` (re-run the installer to pick it up after `git pull`).

### FEATURE: PR #1774 (2026-08-01)
Background: feat(#1747): add SESSION_SYNC toggle (default off) + fixes for #1218 #1564 #1214 #1739
Changes: Automatic Claude Code session sync is now **off by default**. Set `SESSION_SYNC=on` in `agents/.env` to keep the previous automatic fetch-on-shell-startup and push-on-`codes` behavior. Manual `session-sync push/pull/status/reset` is unaffected and continues to work regardless of the setting.;Windows shell startup no longer leaks raw git/SSH diagnostics into the console when the session-sync auto-fetch fails; a single one-line hint is shown instead, matching the Linux/macOS behavior.;`session-sync reset` and `cc-session-mtime` now reject option-looking timestamps read from session JSONL files and pass `--` before filenames, so unusual session data can no longer influence how `touch` interprets its arguments.

### FEATURE: PR #1781 (2026-08-01)
Background: feat(#1741): add CODE_LANG_EXCLUDE repo-level opt-out for language check
Changes: Added `CODE_LANG_EXCLUDE` to let specific repos opt out of the `CODE_LANG` commit-time language check, matched by absolute path or glob (semicolon-separated), same matcher as `ENFORCE_WORKTREE_EXCLUDE`.

### FEATURE: PR #1784 (2026-08-01)
Background: feat(#1769): add /sweep-issues skill; flip /sweep family to apply-by-default
Changes: **Breaking:** every `/sweep` member now applies changes by default. `--dry-run` is the new preview flag, replacing the previous `--apply` opt-in. Running `/sweep`, `bin/sweep-branches.sh`, `bin/sweep-worktrees.sh`, `bin/sweep-plans.sh`, `bin/audit-tests.sh` or `bin/audit-tests-common.sh` with no flags now removes worktrees, deletes local and remote branches, deletes plan files, `git rm`s retired tests, and closes issues for real. Add `--dry-run` to any of them to get the old flagless behavior back. `--apply` is accepted as a no-op where it previously existed. The nightly cron in `.github/workflows/sweep.yml` was adjusted so its effective behavior is unchanged.;Note the flags that changed meaning as a side effect: `--delete-no-pr` (sweep-branches) and `--fix-headers` (audit-tests) used to require `--apply` alongside them and were report-only on their own; each is now destructive by itself.;New `/sweep-issues` skill: finds stale open GitHub issues and closes them in two tiers — meta parents whose sub-issues are all closed, and issues whose referenced test paths no longer exist. Use `--deep` to verify each candidate by running the test it references, `--dry-run` to preview, and `--band-size`/`--band-index` to process large backlogs in chunks. A failed sub-step now surfaces in both the exit status and the error count instead of reporting as a clean empty sweep.;Fixed: `bin/sweep-plans.sh` could claim and delete files that were never workflow planning artifacts, whenever their names happened to start with a hyphen. Files that do not match the recognized artifact naming are now skipped and reported in a `files_skipped_unrecognized` count.

### FEATURE: PR #1786 (2026-08-01)
Background: feat(#1673): replace close-path LLM subagents with deterministic worker scripts
Changes: Commit/push, issue-close-stage, and issue-close-finalize now run as deterministic worker-dispatch scripts instead of LLM subagents, improving reliability and speed.

### FEATURE: PR #1801 (2026-08-01)
Background: fix(#1782): normalize_token() no longer glob-expands or accepts root-equivalent tokens
Changes: Fixed: `--fix-headers --apply` no longer corrupts `# Tests:` headers containing glob characters (`*`, `?`) or root-equivalent path tokens (`/`, `.`, `..`, `./`, `../`).

### FEATURE: PR #1792 (2026-08-01)
Background: fix(#1756): recognise complete as settled in next-step's fail-open re-invoke
Changes: Fixed: `next-step` no longer re-invokes `/write-tests` forever once a session has finished. A completed `write_tests` step is now recognised as settled, so a wrapped-up session reports `ACTION=done` instead of looping back to a step that was already done.;Changed: `bin/workflow/next-step` is now a thin dispatcher over `bin/workflow/lib/next-step/`. Behaviour is unchanged; the recovery commands it prints (`--reset` / `--mark`) still name the entrypoint, not an internal module.

### FEATURE: PR #1808 (2026-08-01)
Background: feat(#1733): migrate workflow state file to an append-only event stream
Changes: The workflow session state file is now an append-only event log (schema v2). Per-step elapsed time is derived from the log automatically, so the opt-in `RECORD_STEP_TIMESTAMPS` setting has been removed — delete it from your `.env` if present. Existing v1 state files are migrated automatically the next time their own session writes; reading a file never rewrites it, so sessions on older releases are unaffected.

### FEATURE: PR #1826 (2026-08-02)
Background: fix(#1779): detect zero-commit branches in resolve-merge-base and fall back to working-tree diff
Changes: `select-tests.sh --auto` and `/run-tests` no longer silently skip all tests on a branch with zero commits — uncommitted and untracked work is now diffed directly against the working tree instead of an empty merge-base range.

### FEATURE: PR #1854 (2026-08-02)
Background: feat(#1849): add preuse-auto-approve hook for Monitor and EnterWorktree
Changes: Monitor and EnterWorktree tool calls no longer pause for a confirmation dialog during normal workflow execution. Set `AUTO_APPROVE_TOOLS=off` in `.env` to restore the previous prompt behavior instantly.

### FEATURE: PR #1853 (2026-08-02)
Background: feat(#1642): single-authority prompt-extraction CLI + blocking gate wiring
Changes: **New**: `bin/check-prompt-extraction` — single-authority CLI for §1.5 code-fence and §1.3 inline-procedure violations; wired as workflow-gate Gate 3 (blocking) and pre-commit backstop; existing violations frozen in `.prompt-extraction-allowlist` ratchet;**Changed**: `bin/check-inline-procedures` converted to advisory adapter (always exits 0, delegates to new engine)

### SECURITY: PR #1857 -- fix/off-clearance-1780 (2026-08-03)
Background: Hardened the OFF-clearance token lifecycle used to gate emergency write access outside the normal worktree workflow.
Changes: Closed a mint/claim race, several cwd-tracking bypasses of the OFF-clearance write guard (popd, cd -, pushd -n, command/builtin prefixes), and a silent-allow gap in the main-worktree write guard for commands whose target could not be extracted.

### FEATURE: PR #1860 (2026-08-07)
Background: fix(#1833): audit-tests.sh primary filter is now target survival, not issue-closed staleness
Changes: Fixed: `audit-tests.sh` (the stale-test sweep) now detects a test whose target source file has been deleted or renamed immediately, instead of waiting for the tracking issue to be closed and age past the stale-months threshold.
