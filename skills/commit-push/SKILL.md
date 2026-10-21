---
name: commit-push
description: Commit and push the branch, then create or reuse a PR (no merge)
---

Commit staged/unstaged changes, push to the remote, and open or reuse a PR.

## Pre-commit check

If tests are missing or the commit hook blocks due to missing tests:
- Never write tests directly in this conversation.
- Invoke the `/write-tests` skill first, then resume commit-push.

If documentation is missing or the commit hook blocks due to missing documentation updates:
- Invoke the `/update-docs` skill first, then resume commit-push.

## Phase 1 (issue-close-stage) pre-flight

Run: `bash "$AGENTS_MAIN_ROOT/bin/detect-non-github.sh" "Phase 1 pre-flight" || NON_GITHUB=1`

When `NON_GITHUB=1` (non-GitHub remote): skip the entire pre-flight block below (including `check-phase1-complete.sh`), then proceed with commit/push as normal — do NOT abort the skill.
When the command exits 0 (GitHub remote, or unknown/fail-open): run the pre-flight as normal.

Skip message on non-GitHub remote (emitted by the script to stdout): `[GITHUB_ISSUES disabled: non-GitHub remote detected, skipping Phase 1 pre-flight]`

For each issue N in the session's `closes_issues` list (the JSON array printed by
`node "$AGENTS_MAIN_ROOT/bin/parse-closes-issues" --session <session-id>` — do not reimplement),
run from the worktree root:

```bash
bash "$AGENTS_MAIN_ROOT/bin/github-issues/check-phase1-complete.sh" <N>
```

Non-zero → abort `/commit-push` and surface stderr (it names the missing
condition: sentinel, history entry, or both). Resolve by invoking
`/issue-close-stage <N>` from the linked worktree, then re-run `/commit-push`.

**Skip this pre-flight when:**
- `closes_issues` is empty, or the session intent file is missing.
- Running from the main worktree (main-worktree commit-push is only valid when
  `ENFORCE_WORKTREE=off`, where the 2-phase split does not apply).

## Procedure

Read `rules/github-issues.md` before CP-1 — on-demand-only, never auto-injected.
Read `rules/coding.md` before CP-2 — on-demand-only, never auto-injected; its Public GitHub Rules govern the commit message and PR body.

CP-1. **Stage changes** per `skills/_shared/commit-push-dispatch.md` "Stage".

CP-2. **Dispatch commit/push/PR to the `commit-push` worker** per `skills/_shared/commit-push-dispatch.md` "Dispatch" and "Outcomes", with handoff step `push_branch`.
   On `bootstrap_pending`: surface "Remote has no default branch yet (new repo) — `/merge-to-main` pushes the first commit as `main`." and go to CP-2c; the advance gate records the bootstrap decision itself.
   On `up_to_date`, `pushed`, `pr_created`, or `pr_reused`: continue to CP-2a.
   On any other outcome: stop without completing `push_branch`.

CP-2a. **Append PR number to session title:** `node "$AGENTS_MAIN_ROOT/bin/cc-session-title" add-pr "<PR_NUMBER>"` (the CLI defaults `<cwd>` to its own working directory) where `<PR_NUMBER>` is extracted from `pr_url` by taking the last path segment (format: `https://github.com/<owner>/<repo>/pull/<N>` → `<N>`). Skip when the outcome carries no PR URL (`pushed`, `up_to_date`). Fail-open.

CP-2b. **Open the PR URL:** run `node "$AGENTS_MAIN_ROOT/bin/open-pr-url.js" "<pr_url>"` when the status is `pr_created` only — `pr_reused` did not create anything, so it must not re-open a tab (parity with the retired `pr-created-open.js`, which fired on `gh pr create` alone).
   The PR URL MUST also appear in this turn's final response text — the dispatcher path has no tool-permission dialog to display it.
   Fail-open: a non-zero exit or missing browser never blocks the flow.

CP-2c. **Complete the step:** `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --advance --step push_branch --complete --next`, then follow its `ACTION`.
   Never merge here — the merge belongs to `/merge-to-main` after `/get-release-approval`.

## WIP mode (`--wip`)

When invoked with `--wip` (for fixup / intermediate commits between substantive work):

- Issue the commit as `git -c workflow.wip=1 commit -m "..."`. The `-c workflow.wip=1`
  pair MUST appear **before** the `commit` subcommand verb — git ignores `-c` placed
  after the subcommand, and `workflow-gate.js` only recognizes the pre-subcommand form.
- The gate skips ONLY `user_verification` for that commit. All other gates
  (`run_tests`, `review_security`, `docs`) still fire.
- Also skip the `review-code-codex` invocation by convention in `--wip` mode (this is a
  skill-level convention; the gate does not track it).
- Do NOT set `workflow.wip` in git config globally — the signal must be scoped to the
  single commit invocation to avoid leakage across commits.
- Works with `--amend`: `git -c workflow.wip=1 commit --amend ...`.
- `--wip` mode also skips Gate 3 (CP-1 unstaged-tracked verification + the `commit-push` worker's staging verification) and Gate 1 (workflow-gate.js unstaged-tracked check), since `workflow.wip=1` signals intentional partial staging.

See `docs/architecture/claude-code/workflow.md` for the signal contract.

## Rules

- Follow all existing commit and push rules.
- If push fails, report the error — do not force-push.
- Never merge and never emit `<<WORKFLOW_USER_VERIFIED>>` — `/get-release-approval` and `/merge-to-main` own both.
- AUTO_MERGE_PR=off (pull_request only): the human merges on the web; /merge-to-main never merges.
- Note: `git branch -D` (force-delete) and `--no-verify` are prohibited.
- `bootstrap_pending` completes `push_branch` with no PR; `/merge-to-main` MM-3b performs the bootstrap push.
- On fallback or step degradation (push retry, PR reuse): run `node "$AGENTS_MAIN_ROOT/bin/supervisor-report" --categories workflow --severity warning --detail "<describe fallback>" --reporter commit-push` (session-id auto-resolves).
- Report observations via /supervisor-report (trigger conditions: rules/supervisor-reporting.md).
