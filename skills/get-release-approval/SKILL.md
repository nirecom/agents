---
name: get-release-approval
description: Run the release preflight, then obtain the user release approval (the single issuer of WORKFLOW_USER_VERIFIED)
user-invocable: false
---

Obtain the user's final release approval for the `user_verification` step.
This skill is the only issuer of `<<WORKFLOW_USER_VERIFIED: reason>>`; protocol and preflight branches: `skills/_shared/user-verified.md`.

## Procedure

When a hook blocks a sanctioned command, a fallback path is taken, or any unexpected outcome occurs, report via /supervisor-report (trigger conditions: rules/supervisor-reporting.md).

GA-1. **Confirm the step:** run `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --session "<session-id>"`.
   `REASON=` `web-merge-pending` or `web-merge-not-ready` → continue to GA-2; its preflight decides the wait.
   Any other `REASON=` than `user_verification` → do not emit; follow its `ACTION` instead.

GA-2. **Preflight:** run `bash "$AGENTS_MAIN_ROOT/skills/get-release-approval/scripts/preflight.sh" --session "<session-id>"` as one standalone call.
   Handle `RUN_TL4=`, `GATE_RC=`, and the `CATEGORY:` lines per `skills/_shared/user-verified.md` "Preflight".
   `PREFLIGHT=web_merge_*` → raise no `AskUserQuestion`; follow that file's "Web-merge channel" (the web merge is the only approval).
   `PREFLIGHT=blocked` → show `PREFLIGHT_REASON` and its recovery (rebase or update the branch, resolve conflicts, wait for CI or reviews, mark the PR ready), then stop without the sentinel.
   `PREFLIGHT=merged_on_web` → the PR was merged outside this session; continue to GA-3 with a reason that says so.
   `PREFLIGHT=ok` → continue to GA-3.
   `PREFLIGHT=web_merge_done` → the human merged on the web; no sentinel; go to GA-4.
   `PREFLIGHT=web_merge_closed` → show `PREFLIGHT_REASON`, then stop without the sentinel.
   `PREFLIGHT=web_merge_pending` → no sentinel; show `PR_URL` as the PR the human merges on the web, then GA-2b.

GA-3. **Emit the sentinel** per `skills/_shared/user-verified.md` "Protocol", as its own Bash call.
   Reason on the pull_request path: `PR #<PR_NUMBER> — approving merge to main` (or `PR #<PR_NUMBER> merged via web UI` for `merged_on_web`).
   Reason on the direct path: a one-line summary of what will be committed and pushed.
   Deny → stop; do not retry.

## Web-merge wait

GA-2b. **Wait for the web merge:** run `bash "$AGENTS_MAIN_ROOT/skills/get-release-approval/scripts/wait-web-merge.sh" --session "<session-id>" --repo "<WORKTREE_PATH>"` with `run_in_background: true`, then end the turn.
   On its completion notice read `WEB_MERGE=`: `merged` → GA-4; `closed` → say the PR was closed without merge and stop; `error` → surface its stderr and stop; `already-running` → end the turn (a poller already waits).
   `WEB_MERGE=timeout` → tell the human, in the conversation language, that polling has ended and that any message sent after the merge resumes the flow, then end the turn.

## Completion

GA-4. **Continue:** run `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --session "<session-id>"` and follow its `ACTION`.

## Rules

- Emit the sentinel at most once per approval, and never before the preflight returns `ok` or `merged_on_web`.
- Never merge, push, or commit here — `/merge-to-main` performs the delivery operation.
- Never emit on a blocked preflight, on Deny, or while waiting for CI.
- Never emit on the web-merge channel (`web_merge_*`): the human's merge on the web is the approval.
