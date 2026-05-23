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
the `## closes_issues` section; canonical parser: `hooks/lib/parse-closes-issues.js` — do not reimplement),
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
2. Run `git diff --cached --stat` to show what will be committed
3. Create the commit with the drafted message
4. Push to the current branch:
   - If no upstream is set: `git push -u origin <branch>`
   - Otherwise: `git push`

Each git command (add, commit, push) must be a **separate Bash call** per `rules/git.md`.

`settings.json` `model` and `effort` fields are auto-updated by the system — exclude them from the commit if they appear in the diff.

### Push retry on non-fast-forward

If `git push` fails with "non-fast-forward" or "fetch first", retry up to 3 times.
Each command is a **separate Bash call** (rules/git.md — do NOT chain with `&&`):

1. `git fetch origin <branch>`
2. `git pull --rebase --autostash origin <branch>`
   — Stop if rebase reports conflicts; surface to user.
3. `git push origin <branch>`

Sleep between attempts: 2s before attempt 2, 5s before attempt 3.
After 3 failures, report to user — do NOT force-push, do NOT use `--no-verify`.

### PR step (after push)

```bash
NON_GITHUB=0
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"; rc=$?
case $rc in
  0) ;;                # GitHub — proceed with gh
  1) NON_GITHUB=1 ;;   # non-GitHub — skip gh invocation
  *) ;;                # unknown (rc=2) — fail-open, keep existing behavior
esac
if [ "${NON_GITHUB:-0}" = "1" ]; then
  echo "[GITHUB_ISSUES disabled: non-GitHub remote detected, skipping gh pr create]"
  # Phase 2: alternative-platform MR creation will be added here.
  exit 0
fi
```

5. **Skip if `ENFORCE_WORKTREE=off`** — direct-main work does not use PRs.

6. **PR resolution (idempotent):**
   ```
   gh pr view --json state,url
   ```
   - `state == OPEN` → reuse the existing PR URL (do NOT create a duplicate).
   - No PR or closed → create with `gh pr create`:
     - Always specify `--head <branch>` explicitly — when the Bash tool CWD is the main
       worktree, `gh` would otherwise default to `main` as the head branch and fail.
     - Use `--body "single-line string"` (no heredoc). Heredoc (`$(cat <<'EOF' ... EOF)`)
       triggers a write classification in enforce-worktree.js and gets blocked.
     - For a minimal PR: `gh pr create --head <branch> --fill`
     - With a custom body: `gh pr create --head <branch> --title "..." --body "..."`
     - When the PR closes one or more tracked issues, emit **one `Closes #<N>` line per entry in `closes_issues`** (primary first, then related in confirmed order) so GitHub auto-closes each issue on merge. After merge, run `/issue-close-finalize --from-session` from the main worktree to promote the sentinels, close the issues, and post resolved-by per N.
     - **Append one marker line per closed issue** to `--body` so
       `find-pr-by-marker.sh` can resolve the merge commit later. One line per
       issue, hardcoded literal (no variable interpolation in the body string):
       ```
       <!-- issue-close-pr-of: <N> -->
       ```
       Place all marker lines at the end of the body, after the `Closes #<N>` lines.
     - **Example (2 issues, primary #444, related #445):**
       ```
       Closes #444
       Closes #445
       <!-- issue-close-pr-of: 444 -->
       <!-- issue-close-pr-of: 445 -->
       ```
       Pass as a static newline-delimited string to `--body` (no heredoc).
     - See `rules/github-issues.md` "Session model".
   Display the PR URL.

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
