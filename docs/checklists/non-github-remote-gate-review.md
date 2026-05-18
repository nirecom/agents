# Manual Review Checklist: Non-GitHub Remote Gate

Layer 2 test checklist for `bin/is-github-dotcom-remote` gate behavior.
Automated tests in `tests/feature-gh-skip-non-github-helper.sh` and
`tests/feature-gh-skip-non-github-static.sh` cover mechanical correctness (Layer 1).
This checklist covers agent behavior that cannot be tested mechanically.

## Before review: prerequisites

- [ ] Run automated tests: `bash tests/feature-gh-skip-non-github-helper.sh && bash tests/feature-gh-skip-non-github-static.sh`
- [ ] Both test suites pass

## workflow-init gate (Step 3 routing)

- [ ] On non-GitHub remote: step 3 skips `gh issue view`, proceeds as Path C (no issue)
- [ ] On non-GitHub remote: session title is not set via `gh`
- [ ] On GitHub remote: existing behavior unchanged

## clarify-intent gate (Completion steps)

- [ ] On non-GitHub remote: `gh issue edit` and `gh issue create` are skipped
- [ ] Skip message `[GITHUB_ISSUES disabled: non-GitHub remote detected, skipping ...]` is emitted
- [ ] On GitHub remote: existing behavior unchanged

## commit-push gate

- [ ] On non-GitHub remote: `gh pr create` is skipped
- [ ] On non-GitHub remote: `git push` still executes
- [ ] Phase 2 extension comment is present (marker for future MR creation)
- [ ] On GitHub remote: `gh pr create` still runs as before

## issue-close-stage gate

- [ ] On non-GitHub remote: entire skill is skipped with clear message
- [ ] On GitHub remote: existing behavior unchanged

## issue-close-finalize gate

- [ ] On non-GitHub remote: entire skill is skipped with clear message
- [ ] On GitHub remote: existing behavior unchanged

## Cross-cutting

- [ ] Skip messages use exact format: `[GITHUB_ISSUES disabled: non-GitHub remote detected, skipping <operation>]`
- [ ] Work environment hostname/platform name does NOT appear in any code, docs, or commit messages
- [ ] Personal GitHub repos are unaffected (test with a GitHub remote repo)
