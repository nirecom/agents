## Archived
- [2026](changelog/2026.md) — 223 entries

### FEATURE: PR #2815 (2026-10-27)
Background: fix(#2808): update codex through npm directly after claude and codex exit
Changes: Windows install no longer prints an npm cleanup EPERM warning when updating Codex CLI; it waits for running Claude Code and Codex to exit, then updates through npm directly.

### FEATURE: PR #2821 (2026-10-28)
Background: fix(#2811,#2813): continue confirm-plan presentation under stop_hook_active once per receipt, and point feature-2013 B20 at the current skill dispatch
Changes: The plan approval dialog now follows a plan presentation even when that turn came after a Stop hook block, or when the transcript flush lagged but completed before the turn settled (#2811); a flush that lags past that point is tracked in #2822.

### FEATURE: PR #2823 (2026-10-28)
Background: feat(#2327): scope review-tests re-reviews after implementation changes to the delta
Changes: review-tests re-reviews after an implementation change now read only the changed and covering tests, falling back to a full review when coverage cannot be determined (#2327)

### FEATURE: PR #2751 (2026-10-29)
Background: feat(#2672, #2725): add four CPR entries and the new rules/architecture-principles.md
Changes: Core principles gained four entries (Release Is the Goal; Quality, Cost, Delivery; Evidence First; Root Cause Analysis), and a new on-demand design-principles rule (exit before gate, shift left) is now read when outlining, detailing and writing code.

### FEATURE: PR #2830 (2026-10-29)
Background: feat(#2768): plan-sync makes one commit per user prompt
Changes: plan-sync now publishes one commit per user prompt instead of one per plan write, so the plan repository keeps the versions you saw, not every intermediate draft. When the remote forbids force pushes, a turn-diff link shows that prompt's changes.

### FEATURE: PR #2756 (2026-10-29)
Background: test(#2723): split the slowest test files into parallel entrypoints
Changes: Slow test files are split into smaller entrypoints that run in parallel, so a full test run spends less time stuck behind a single long file.

### FEATURE: PR #2840 (2026-10-31)
Background: feat(#2507): run the pre-commit checks in one Node.js process
Changes: Commits are faster: the pre-commit hook now runs all of its checks in a single Node.js process instead of spawning bash, grep and git per staged file. Node.js is now required to commit; without it the hook stops the commit and says why.;The pre-commit secret scan now stops the commit on a malformed `--manifest` frame, and detects zero-width and bidi-override characters regardless of the hook's locale.;In blocklist and allowlist patterns, `\w` now includes `_` on every OS (GNU semantics).

### FEATURE: PR #2845 (2026-10-31)
Background: feat(#2814): state the intent > outline > detail priority in codex pl...
Changes: Plan reviews now hold the detail to the approved outline and the outline to the intent. When a reviewer finds that the problem sits in an upstream plan, the review pauses and asks you to choose how to proceed (keep, return upstream, accept, or stop) instead of silently patching the downstream plan.

### FEATURE: PR #2844 (2026-10-31)
Background: feat(#2652,#2446,#2578): merge machine handoff records into the state...
Changes: Session handoff records are now stored in the workflow state file; handoff.md is no longer written (existing files are still read during a migration window).

### FEATURE: PR #2848 (2026-10-31)
Background: feat(#2692): scale test parallelism automatically from external load,...
Changes: Test runs now pick their parallelism automatically: they leave room for other apps by watching external CPU load and free memory, ramp up gradually when several runs start at once, and share lanes fairly between concurrent runs. The lane status display shows why each run got its width.

### FEATURE: PR #2854 (2026-10-31)
Background: fix(#2842,#2636): exclude merge-incoming paths from the review-tests ...
Changes: review-tests: files that a merge brings in are excluded from the header map, so a review during a merge no longer times out, and exit 8 now says how to recover.

### FEATURE: PR #2857 (2026-10-31)
Background: fix(#2456): install CodeGraph @latest again instead of the 1.6.0 pin
Changes: CodeGraph installs track the latest release again (`@latest`) instead of the temporary 1.6.0 pin; 1.6.2 carries the upstream fix for the Windows console flicker.

### FEATURE: PR #2861 (2026-10-31)
Background: feat(#2770,#2796): scan only changed lines, carry glossary grants over unrelated edits, read the glossary from the branch worktree
Changes: Glossary check asks for confirmation less often: it scans only changed lines of staged files, keeps an accepted grant across unrelated edits, and reads the glossary from the branch's own worktree (#2770, #2796).

### FEATURE: PR #2864 (2026-11-01)
Background: feat(#2862): upgrade an already-installed RTK in the installers when RTK=on
Changes: With `RTK=on`, the installer now upgrades an already-installed RTK instead of leaving it as is. If the upgrade fails, the installed version is kept and setup continues.

### FEATURE: PR #2866 (2026-11-01)
Background: fix(#2828): grant WORKFLOW_GLOSSARY_ACCEPTED in resumed sessions and ...
Changes: Fixed: `WORKFLOW_GLOSSARY_ACCEPTED` is no longer rejected as "nothing pending" in a resumed session, and one sentinel now covers findings of every stage that has one; when it grants nothing it says why.

### FEATURE: PR #2867 (2026-11-01)
Background: feat(#299,#1127): title workflow-init sessions with the issue title v...
Changes: Sessions started with `/workflow-init #N` are now titled `#N <issue title>` in the VS Code session list and the Claude app, fetched from GitHub or GitLab. The old title markers (⏳, PR #M, ✓) and `bin/cc-session-title` are removed.

### FEATURE: PR #2869 (2026-11-01)
Background: feat(#2863): require node:test in new JS test entrypoints
Changes: New JavaScript test files must use node:test: the edit-time and commit-time test gates now block a new `tests/<category>/*.js` entrypoint that does not load node:test (`MISSING_TEST_RUNNER`), with a hint pointing to node:test plus `tests/lib/harness.js`. Existing plain-script tests are unaffected.

### FEATURE: PR #2870 (2026-11-01)
Background: feat(#2853,#2448,#2515,#2795): run the supervisor audit before plan a...
Changes: The EM Supervisor audit now reviews each plan (intent / outline / detail) before you approve it, not after, so a fix it asks for no longer forces you to approve the same plan twice.;The audit stops after 2+1 rounds per stage and hands the decision to you, instead of looping.;Closing a session no longer skips a supervisor audit that was re-armed.

### FEATURE: PR #2876 (2026-11-01)
Background: feat(#2865): migrate the remaining non-node:test JS tests to node:tes...
Changes: Every JavaScript test file must now use node:test, not only new ones. The edit-time and commit-time test gates block any `tests/<category>/*.js` entrypoint that does not load node:test (`MISSING_TEST_RUNNER`). All existing plain-script tests in this repository were migrated, so nothing is blocked today.

### FEATURE: PR #2872 (2026-11-01)
Background: feat(#2763): cut glossary drift false positives with an Identifier field (recorded late)
Changes: The glossary drift check reports fewer false positives: an identifier written in code spans or declared in a glossary entry's new Identifier field is no longer flagged, and neither are inflected forms. A second new field for excluding a different word spelled like a term had no effect and was later replaced by `Short forms`.

### FEATURE: PR #2880 (2026-11-02)
Background: feat(#2873): one CONFIRM Allow accepts a WARN or CONTINUE pre-confirm...
Changes: Fixed: once the pre-confirm audit cap is reached, a single CONFIRM approval now accepts a WARN or CONTINUE audit finding instead of requiring a second approval or blocking approval.

### FEATURE: PR #2882 (2026-11-02)
Background: feat(#2875,#2337,#2696,#1192,#322): reset per-cycle state on re-init and reclaim finished worktree leftovers
Changes: Fixed stale previous-cycle worktree references surviving a same-session re-init, and a guard block when the Final Report appears only in a tool result.;Worktree directories left behind by a partial Windows removal can now be reclaimed safely when their ownership is confirmed.

### FEATURE: PR #2884 (2026-11-02)
Background: fix(#2646): refuse RUN_TESTS_UNRUNNABLE_ACCEPTED when UNRUNNABLE incl...
Changes: Fixed: a run that named nonexistent test files could be accepted as "unrunnable" and mark the test step complete. Fix the test path and re-run; unrunnable runs caused only by missing runtimes can still be accepted as before.

### FEATURE: PR #2881 (2026-11-02)
Background: docs(#2461,#2764): describe Jev continuation judgments and the AskUse...
Changes: Jev can now advise next-step to pause before invoking the next skill, and can let the Stop guard continue a turn it would otherwise stop (#2461).;Jev can answer AskUserQuestion dialogs that Claude explicitly marks as already settled by the conversation; dialogs raised by a skill always reach the user (#2764). Turn it off alone with `JEV_AUTO_SKIP_ASKUSER=off`.

### FEATURE: PR #2897 (2026-11-02)
Background: fix(#2892): show "already up to date" for winget exit code -197833518...
Changes: The RTK and glab installers now say "already up to date" when nothing needs upgrading, instead of the ambiguous "up to date or upgrade failed".

### FEATURE: PR #2898 (2026-11-02)
Background: fix(#2849,#2781): widen the commit-push gate decision limit and fail ...
Changes: Committing a large change no longer fails because the documentation checks run out of time; the commit-push gate now waits up to 110 s for them.

### FEATURE: PR #2887 (2026-11-02)
Background: feat(#2814): share review criteria and severity across reviewers, rec...
Changes: Reviewers (plan, code, security, tests) now share one set of review criteria and one severity definition, so findings below the reporting bar and inconsistent severities are cut.;When you correct the direction of an approved plan in conversation, the correction is recorded and honored by reviewers instead of being asked again as an upstream inconsistency.;Reviewers now flag a lower plan that copies or narrows a decision already settled in an upper plan.

### FEATURE: PR #2905 (2026-11-02)
Background: refactor(#2896): move shared md files from agents/lib/ to skills/_sha...
Changes: Shared on-demand md files now live in skills/_shared/ only; agents/lib/ is removed.

### FEATURE: PR #2906 (2026-11-03)
Background: feat(#2763): replace the glossary per-entry exclusion field with Shor...
Changes: Glossary entries can declare a `Short forms` field (a shorter form of a multi-word term, e.g. `step` for `workflow step`); it replaces the exclusion field added in PR #2872, which had no effect.

### FEATURE: PR #2913 (2026-11-03)
Background: feat(#2903, #2904, #1926, #2225, #2303, #1076): fix the Final Report follow-up and Post-Merge sections
Changes: Final Report: follow-up lines start with their issue number, entries the user already knows about are filed without a second question, and Post-Merge restart judgment reads the installers' declared deploy list (#2903, #2904, #1926, #2225, #2303, #1076).
