---
name: deliver
description: Perform the approved delivery operation — merge the PR (pull_request path), bootstrap-push a new repo, or commit and push to the default branch (direct path)
user-invocable: false
---

Perform the delivery operation the user approved in `/get-release-approval`, then complete the `deliver` step.
Every step is idempotent: a re-run after a partial delivery resumes without repeating a landed operation.

## Procedure

When a hook blocks a sanctioned command, a fallback path is taken, or any unexpected outcome occurs, report via /supervisor-report (trigger conditions: rules/supervisor-reporting.md).

DL-1. **Confirm the step:** run `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --session "<session-id>"`.
   `REASON=` other than `deliver` → stop and follow its `ACTION`; never merge or push before the approval is recorded.

DL-2. **Read the delivery path:** run `node "$AGENTS_MAIN_ROOT/bin/session-close-detect-route.js" --session "<session-id>"` and read `ROUTE=` (the recorded `delivery_path`).
   `pull_request` → DL-3.
   `direct` → DL-4.

## Pull request delivery

DL-3. **Merge the PR (pull_request):** run `node "$AGENTS_MAIN_ROOT/bin/workflow/pr-state"` and read `PR_STATE=` / `PR_NUMBER=`.
   `MERGED` → already delivered; go to DL-5.
   `OPEN` and `PR_NUMBER` differs from the PR number in the `/get-release-approval` GA-3 approval reason → stop and re-run `/get-release-approval` instead of merging.
   `OPEN` → issue the merge as one direct Bash call, never wrapped in a helper:
   github: `gh pr merge <PR_NUMBER> --squash --delete-branch`
   gitlab: `glab mr merge <PR_NUMBER> --squash --remove-source-branch`
   Merge failure → surface the error and stop; on success go to DL-5.
   `NONE` → run `bash "$AGENTS_MAIN_ROOT/bin/probe-remote-bootstrap.sh" "<WORKTREE_PATH>"`; `preBootstrap` true with `classification` `empty-repo` (the `/commit-push` outcome was `bootstrap_pending`) → DL-3b; otherwise go to DL-5, which accepts an earlier bootstrap push and refuses when `/commit-push` never opened the PR.
   `CLOSED` or `UNKNOWN` → surface the state and stop.

DL-3b. **Bootstrap push (empty remote):** run `bash "$AGENTS_MAIN_ROOT/skills/deliver/scripts/bootstrap-complete.sh" "<WORKTREE_PATH>" "<BRANCH>" "<OWNER_REPO>" "<session-id>"` as one standalone call.
   Exit 0 → read `bootstrap_commit_sha`, `default_branch_set`, and `pushed_ref` from its JSON; warn when `default_branch_set` is false; go to DL-5.
   Exit 2 → the remote is no longer empty; surface stderr, re-run `/commit-push`, and stop.
   Exit 4 → user_verification is not complete; stop and run `/get-release-approval` (never emit USER_VERIFIED here).
   Exit 1 or 3 → surface stderr and stop.

## Direct delivery

DL-4. **Commit and push (direct):** follow `skills/_shared/commit-push-dispatch.md` with handoff step `deliver`.
   `pushed` or `up_to_date` → DL-5.
   Any other outcome → stop per that file's outcome branch.

## Completion

DL-5. **Complete the step:** run `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --advance --step deliver --complete --next` and follow its `ACTION`.
   A refusal (`no-release-evidence`) means the delivery is not observable yet — surface it and stop; never re-declare.

## Rules

- Never emit `<<WORKFLOW_USER_VERIFIED>>` here — `/get-release-approval` owns it.
- Issue each merge command as a bare Bash call so the merge gate sees it.
- Never force-push and never use `--admin` to bypass required checks.
- On fallback or step degradation: `node "$AGENTS_MAIN_ROOT/bin/supervisor-report" --categories workflow --severity warning --detail "<describe fallback>" --reporter deliver`.
