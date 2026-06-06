---
name: commit-push
description: Commit and push changes, then create or reuse a PR with optional merge
---

Commit staged/unstaged changes, push to the remote, and open or reuse a PR.

## Pre-commit check

If tests are missing or the commit hook blocks due to missing tests:
- Never write tests directly in this conversation.
- Invoke the `/write-tests` skill first, then resume commit-push.

If documentation is missing or the commit hook blocks due to missing documentation updates:
- Invoke the `/update-docs` skill first, then resume commit-push.

## Phase 1 (issue-close-stage) pre-flight

```bash
NON_GITHUB=0
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"; rc=$?
case $rc in
  0) ;;                # GitHub — proceed with gh
  1) NON_GITHUB=1 ;;   # non-GitHub — skip gh invocation
  *) ;;                # unknown (rc=2) — fail-open, keep existing behavior
esac
if [ "${NON_GITHUB:-0}" = "1" ]; then
  echo "[GITHUB_ISSUES disabled: non-GitHub remote detected, skipping Phase 1 pre-flight]"
fi
```

When `NON_GITHUB=1`: skip the entire pre-flight block below (including `check-phase1-complete.sh`).
When `NON_GITHUB=0` or exit 2 (fail-open): run the pre-flight as normal.

For each issue N in the session's `closes_issues` list (parsed from
`${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/<session-id>-intent.md` —
the `## Issues` section; canonical parser: `hooks/lib/parse-closes-issues.js` — do not reimplement),
run from the worktree root:

```bash
bash "$AGENTS_CONFIG_DIR/bin/github-issues/check-phase1-complete.sh" <N>
```

Non-zero → abort `/commit-push` and surface stderr (it names the missing
condition: sentinel, history entry, or both). Resolve by invoking
`/issue-close-stage <N>` from the linked worktree, then re-run `/commit-push`.

**Skip this pre-flight when:**
- `closes_issues` is empty, or the session intent file is missing.
- Running from the main worktree (main-worktree commit-push is only valid when
  `ENFORCE_WORKTREE=off`, where the 2-phase split does not apply).

## Procedure

1. Stage changes with `git add`

2-6. **Delegate commit/push/PR to commit-push-worker**:
   Resolve `PLANS_DIR` and `ENFORCE_WORKTREE` before delegating.
   ```
   Agent({ subagent_type: "commit-push-worker", prompt: JSON.stringify({
     commit_message: COMMIT_MESSAGE,
     branch: BRANCH,
     closes_issues: CLOSES_ISSUES,
     pr_body_template: PR_BODY,
     wip_mode: WIP_MODE,
     enforce_worktree: ENFORCE_WORKTREE,
     agents_config_dir: AGENTS_CONFIG_DIR,
     artifact_dir: PLANS_DIR
   }) })
   ```
   On `push_failed` or `conflict`: surface summary + artifact_path to user and stop.
   On `pr_created` or `pr_reused`: extract PR URL from summary for step 7.
   On `bootstrap_pending` (issue #772 — remote has no default branch): surface guidance text "Remote has no default branch yet (new repo). Run `/worktree-end` to push the first commit as `main` and set the default branch — this is the bootstrap path, not a normal push." Skip step 7 (no merge confirmation; nothing was pushed). Do NOT emit `<<WORKFLOW_USER_VERIFIED>>` — `/worktree-end` Step 2b owns that sentinel. Stop.

   `settings.json` `model` and `effort` fields are auto-updated by the system — exclude them from the commit if they appear in the diff.

7. **Merge prompt:**

   Check `ENFORCE_WORKTREE`:
   `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off ENFORCE_WORKTREE on && echo OFF || echo ON'`

   **(a) `ENFORCE_WORKTREE=on`:** Output `PR #<N> is open: [<url>](<url>)` and stop.
   `/worktree-end` owns the merge prompt and sentinel for worktree mode.

   **(b) `ENFORCE_WORKTREE=off` (unchanged):** Output `PR #<N> is open: [<url>](<url>)`,
   then `AskUserQuestion`: "PR #<N> — merge, wait, or abort?"
   - **merge**: `gh pr merge --squash --delete-branch`, then `git fetch --prune origin`.
   - **wait** / **abort**: display URL and stop.

   If `AskUserQuestion` is unavailable, default to **wait**.

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

See `docs/architecture/claude-code/workflow.md` for the signal contract.

## Rules

- Follow all existing commit and push rules.
- If push fails, report the error — do not force-push.
- Merge is always user-confirmed — never auto-merge without `AskUserQuestion`.
  Exception: `/worktree-end` when `AUTO_MERGE_PR=on` (worktree mode only).
  In worktree mode this skill defers entirely to `/worktree-end` (Step 7a).
- Note: `git branch -D` (force-delete) and `--no-verify` are prohibited.
- `bootstrap_pending` is terminal for `/commit-push` — defer the actual push to `/worktree-end` Step 2b. No PR is created and no user-verified sentinel is emitted in `/commit-push` for this status.
