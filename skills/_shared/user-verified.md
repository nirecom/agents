# User Verification — Shared Protocol

`<<WORKFLOW_USER_VERIFIED: reason>>` is the **final** approval from the user before
releasing the work (merge or direct push). Emit it exactly once, at the moment the user is
asked "is this ready to ship?".

## Who emits

`/get-release-approval` is the only emitter. It runs as the `user_verification` step, after `/commit-push` opened the PR (pull_request path) and before `/deliver`.
Never emit it from any other skill or step — on the pull_request path the user approves the merge of a specific PR, so the PR must exist first.

## Preflight — risk-category gate (#833)

Run `bash "$AGENTS_MAIN_ROOT/skills/get-release-approval/scripts/preflight.sh" --session "<session-id>"` once as one standalone call.
It first resolves TL4 readiness with the sanctioned reader `confirm-off RUN_TL4 off` and prints the verdict as `RUN_TL4=`.
It then runs `bin/check-verification-gate.sh` and prints its exit as `GATE_RC=` followed by the classifier's `CATEGORY:` lines (`CATEGORY: <token>\tQUESTION: <text>`).
It ends with `PREFLIGHT=` and `PREFLIGHT_REASON=` for the PR mergeability check.

### RUN_TL4 gate (precedes all modes)

- `OFF` (RUN_TL4 off — the default; unset counts as off) → TL4 verification is not enabled; do not raise any `AskUserQuestion`; log each `CATEGORY:` line to `WORKTREE_NOTES.md ## Unverified Categories` with the annotation `skipped: RUN_TL4=off (TL4 verification not enabled)`; then proceed to Protocol, skipping the Interactive / Non-interactive / Failure branches below.
- In this off path, if `GATE_RC` is 2 or 3 (classifier failed): still raise no `AskUserQuestion`; emit one stderr warning and skip the category trace; then proceed to Protocol. No ask can ever occur when RUN_TL4=off.
- `ON` (RUN_TL4 on) → run the preflight branches below unchanged.
- `ERROR` (config read failed) → fail-safe to the on path; run the preflight branches below unchanged; never silence the gate on an ambiguous read.

### Interactive mode (default)

Count matched categories:
- **Zero matches** → no risk category. Skip the gate; proceed to Protocol.
- **One match** → single-choice AskUserQuestion using the `QUESTION:` text. Options: `Yes — verified` / `No — skip verification this time`. `Yes`: proceed. `No`: proceed but log the unverified category to `WORKTREE_NOTES.md ## Unverified Categories`.
- **Multiple matches** → single multi-select AskUserQuestion with one option per category (label = `QUESTION:` text), plus `Skip all — proceed without verification`. Selected categories are verified. Unselected categories are logged to `WORKTREE_NOTES.md ## Unverified Categories`. Emission proceeds regardless.

### Non-interactive mode

When `$CI` or `$CLAUDE_NON_INTERACTIVE` is set:
- Skip AskUserQuestion.
- Emit one stderr warning per matched category: `WARNING: verification-gate category <token> not interactively confirmed (non-interactive mode).`
- Log each matched category to `WORKTREE_NOTES.md ## Unverified Categories`.
- Proceed with sentinel emission.

### Failure mode

`GATE_RC=3` → fail-safe. In interactive mode ask "Verification gate could not run — proceed anyway?" (Yes/No). In non-interactive mode: log warning, proceed.

This gate runs after `check-unstaged-tracked.sh` and before the `WORKFLOW_USER_VERIFIED` sentinel. The two guards are orthogonal.

## Protocol

**Emit the sentinel directly** as its own Bash call — no narrative prelude, no PR URL restated in chat:

    echo "<<WORKFLOW_USER_VERIFIED: {reason}>>"

The `: <reason>` is mandatory — describe what the user is approving
(e.g. `"PR #314 — approving merge to main"`). Set the Bash `description` to the
same sentence so the permission dialog shows it.

`hooks/show-user-verified-context.js` fires before the dialog (SSOT) and surfaces:
- Staged files (`git diff --cached --name-only`), or `(none)`
- `Open PR: <url>` when available
- The approval instruction line shown above the Allow / Deny buttons

Do not pre-print this context, the PR URL, or the approval instruction in chat —
the hook is the single source of truth for the dialog's surrounding text.

**User answers the dialog**

- **Allow** → proceed to the next step (`/deliver`).
- **Deny** → stop. Do not retry.

## Notes

- Detection is on `tool_input.command` matching the sentinel form. Sentinel strings in
  stdout (cat/grep output) do not trigger the hook.
- Unverified categories are persisted to WORKTREE_NOTES.md ## Unverified Categories so /worktree-end can show them in the final summary.
- When `RUN_TL4=off` the preflight raises no ask and matched categories are logged with the `skipped: RUN_TL4=off` annotation; on classifier error the log is skipped and only a stderr warning is emitted.
