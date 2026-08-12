# shellcheck shell=bash
# tests/TL3-skill-worktree-start-auto-naming/case-session.sh
# Tests: skills/worktree-start/SKILL.md, skills/worktree-start/scripts/derive-worktree-name.sh
# Tags: worktree, start, session, idempotency, claude-e2e, TL3, scope:common
#
# WSE-1..WSE-7 — no-argument invocation. The session hosts a workflow run, so
# WS-2 resolves intent.md through the session id and passes no --headless.
# Sourced by ../TL3-skill-worktree-start-auto-naming.sh after helpers.sh.

echo ""
echo "=== TL3: worktree-start, no-argument (session-hosted) invocation ==="

WSS_SID="a7a7a7a7-0000-0000-0000-000000000001"
ws_setup "session"

# Title with no issue reference: closes_issues stays empty, so D4 never calls
# `gh` and the derived name is a pure function of this file — deterministic
# across both runs, which is what the idempotency assertion needs.
{
    printf '**Title:** Fix the sample widget renderer\n\n'
    printf '## Issues\n\n'
    printf '\n## Scope\n\n- fixture\n'
} > "$WORKFLOW_PLANS_DIR/$WSS_SID-intent.md"

ws_derive "$WSS_SID"
if [ "$WS_DERIVE_RC" -eq 0 ] && [ -n "$WS_TASK" ] && [ -n "$WS_BRANCH_TYPE" ] && [ -n "$WS_REPO_NAME" ]; then
    pass "WSE-1. the oracle run of derive-worktree-name.sh resolved the session intent: TASK_NAME=$WS_TASK BRANCH_TYPE=$WS_BRANCH_TYPE REPO_NAME=$WS_REPO_NAME"
else
    fail "WSE-1. oracle derive run failed (rc=$WS_DERIVE_RC) — the rest of this case cannot be judged. output: $WS_DERIVE_OUT"
fi

WSS_WANT_PATH="$(norm_path "$(native_path "$WORKTREE_BASE_DIR/$WS_TASK/$WS_REPO_NAME")")"
WSS_WANT_BRANCH="refs/heads/$WS_BRANCH_TYPE/$WS_TASK"

ws_claude "$WSS_SID" "$(ws_prompt 'A workflow session hosts this run and AskUserQuestion is available to you, so WS-2 must NOT be given --headless.')"
if [ "$WS_RC" -eq 0 ]; then
    pass "WSE-2. the live claude -p run following SKILL.md completed"
else
    fail "WSE-2. claude -p exited $WS_RC. output: $WS_OUT"
fi

ws_assert_no_prompt "WSE-3."

WSS_GOT_BRANCH="$(ws_branch_of "$WSS_WANT_PATH")"
if [ -n "$WSS_GOT_BRANCH" ]; then
    pass "WSE-4. the model created a worktree at exactly the path derive-worktree-name.sh emits ($WSS_WANT_PATH) — no hand-written name"
else
    fail "WSE-4. no worktree registered at $WSS_WANT_PATH. registered: $(git -C "$WS_REPO" worktree list --porcelain | tr '\n' ' ') | claude output: $WS_OUT"
fi

if [ "$WSS_GOT_BRANCH" = "$WSS_WANT_BRANCH" ]; then
    pass "WSE-5. its branch is the derived <BRANCH_TYPE>/<TASK_NAME> ($WSS_WANT_BRANCH)"
else
    fail "WSE-5. branch mismatch — want=$WSS_WANT_BRANCH got=${WSS_GOT_BRANCH:-<none>}"
fi

# --- idempotency: a second invocation must attach, not duplicate -------------
WSS_COUNT_1="$(ws_worktree_count)"
ws_claude "$WSS_SID" "$(ws_prompt 'A workflow session hosts this run and AskUserQuestion is available to you, so WS-2 must NOT be given --headless.')"
WSS_COUNT_2="$(ws_worktree_count)"

if [ "$WSS_COUNT_2" = "$WSS_COUNT_1" ] && [ "$WSS_COUNT_2" = "2" ]; then
    pass "WSE-6. the second invocation reused the existing worktree — still exactly one linked worktree plus the main checkout"
else
    fail "WSE-6. worktree count changed across the re-run (before=$WSS_COUNT_1 after=$WSS_COUNT_2, expected 2 both times). registered: $(git -C "$WS_REPO" worktree list --porcelain | tr '\n' ' ') | claude output: $WS_OUT"
fi

# A duplicate that WS-2's reuse check missed would surface as a second branch
# even when `git worktree add` failed and left no new registration.
WSS_BRANCHES="$(git -C "$WS_REPO" for-each-ref --format='%(refname)' "refs/heads/$WS_BRANCH_TYPE/" | wc -l | tr -d ' ')"
if [ "$WSS_BRANCHES" = "1" ]; then
    pass "WSE-7. the re-run created no second branch under refs/heads/$WS_BRANCH_TYPE/"
else
    fail "WSE-7. expected exactly 1 branch under refs/heads/$WS_BRANCH_TYPE/, found $WSS_BRANCHES: $(git -C "$WS_REPO" for-each-ref --format='%(refname)' "refs/heads/$WS_BRANCH_TYPE/" | tr '\n' ' ')"
fi
