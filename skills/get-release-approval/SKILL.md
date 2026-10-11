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
   `REASON=` other than `user_verification` → do not emit; follow its `ACTION` instead.

GA-2. **Preflight:** run `bash "$AGENTS_MAIN_ROOT/skills/get-release-approval/scripts/preflight.sh" --session "<session-id>"` as one standalone call.
   Handle `RUN_TL4=`, `GATE_RC=`, and the `CATEGORY:` lines per `skills/_shared/user-verified.md` "Preflight".
   `PREFLIGHT=blocked` → show `PREFLIGHT_REASON` and its recovery (rebase or update the branch, resolve conflicts, wait for CI or reviews, mark the PR ready), then stop without the sentinel.
   `PREFLIGHT=merged_on_web` → the PR was merged outside this session; continue to GA-3 with a reason that says so.
   `PREFLIGHT=ok` → continue to GA-3.

GA-3. **Emit the sentinel** per `skills/_shared/user-verified.md` "Protocol", as its own Bash call.
   Reason on the pull_request path: `PR #<PR_NUMBER> — approving merge to main` (or `PR #<PR_NUMBER> merged via web UI` for `merged_on_web`).
   Reason on the direct path: a one-line summary of what will be committed and pushed.
   Deny → stop; do not retry.

## Completion

GA-4. **Continue:** run `node "$AGENTS_MAIN_ROOT/bin/workflow/next-step" --session "<session-id>"` and follow its `ACTION`.

## Rules

- Emit the sentinel at most once per approval, and never before the preflight returns `ok` or `merged_on_web`.
- Never merge, push, or commit here — `/deliver` performs the delivery operation.
- Never emit on a blocked preflight, on Deny, or while waiting for CI.
