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
Changes: `git worktree remove` no longer incorrectly blocked when Git Bash supplies a POSIX-form working directory path (e.g., `/c/git/agents`) as `toolInput.cwd`. Fix is root-cause level: `isMainCheckout` now normalizes POSIX paths before passing them to `spawnSync`, symmetric with the existing normalization in `findRepoRootForBash`.

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
