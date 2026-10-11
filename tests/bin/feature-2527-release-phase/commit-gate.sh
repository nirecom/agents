#!/usr/bin/env bash
# commit-gate.sh — #2527 3-4: commit gate reads commitGateOf(step) and recorded (non-navigated) status.
# Tests: hooks/workflow-gate/commit-gate-steps.js, hooks/workflow-gate.js
# Tags: scope:issue-specific, workflow, release-phase, commit-gate
# TL2: workflow-gate.js fed a `git commit` payload. The blocking cases leave review_security pending
# as a canary so the incomplete list is observable; the closing cases settle every prerequisite and
# assert the parsed JSON decision is approve, so an always-blocking gate cannot pass.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# TL3 gap (not caught here): the hook registration order in a live session.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh
# category: hook-registration.
rp_setup
trap rp_teardown EXIT
# The gate enforces only on its own repo (isAgentsSessionRepo): run it from a checkout copy
# attached to the fixture repo, so the fixture's commits are the gate's own.
# shellcheck source=../../lib/session-repo-fixture.sh
source "$_HELPERS_SCRIPT_CHECKOUT_ROOT/tests/lib/session-repo-fixture.sh"
session_repo_fixture_create "$RP_TMP/gate-co" || fail "fixture" "gate checkout copy failed"
session_repo_fixture_attach "$RP_TMP/gate-co" "$RP_REPO" || fail "fixture" "gate checkout attach failed"
GATE_JS="$(session_repo_fixture_path "$RP_TMP/gate-co" hooks/workflow-gate.js)"

LIST_HEAD="the following workflow steps are not complete"
# commit_in <sid> <repo-m> — stages a code file and asks the gate about `git -C <repo> commit`.
commit_in() {
  printf 'code %s\n' "$RANDOM" >> "$2/src.txt"
  git -C "$2" add src.txt
  gate_bash "$1" "$2" "git -C $2 commit -m x"
}
# first_line <out> — the incomplete-steps line of a block message.
first_line() { printf '%s\n' "$1" | grep -o "$LIST_HEAD[^\\\"]*" | head -n 1; }

case_begin "push_branch / deliver are exempt (pull_request, both pending)" "hooks/workflow-gate/commit-gate-steps.js"
mk_state '{"sid":"cg-ex","path":"pull_request","upto":"review_security","steps":"review_security=pending;push_branch=pending;user_verification=pending;deliver=pending"}'
out="$(commit_in cg-ex "$RP_REPO_M")"
line="$(first_line "$out")"
check_contains "gate blocks with the incomplete list" "$line" "review_security"
check_not_contains "push_branch not required at commit" "$line" "push_branch"
check_not_contains "deliver not required at commit" "$line" "deliver"
case_end

case_begin "direct: commit before deliver requires user_verification" "hooks/workflow-gate/commit-gate-steps.js"
export ENFORCE_WORKTREE=off
mk_state '{"sid":"cg-d","path":"direct","upto":"review_security","steps":"review_security=pending;user_verification=pending;deliver=pending"}'
out="$(commit_in cg-d "$RP_REPO_M")"
line="$(first_line "$out")"
check_contains "canary present" "$line" "review_security"
check_contains "user_verification required outside a worktree" "$line" "user_verification"
check_not_contains "deliver still exempt" "$line" "deliver"
case_end

case_begin "direct: after deliver, uv post-push pending blocks the next commit (C4)" "hooks/workflow-gate/commit-gate-steps.js"
mk_state '{"sid":"cg-c4","path":"direct","upto":"pre_final_report_gate","steps":"user_verification=pending;review_security=pending","uvReset":"post-push"}'
out="$(commit_in cg-c4 "$RP_REPO_M")"
line="$(first_line "$out")"
check_contains "canary present" "$line" "review_security"
check_contains "gate reads the recorded pending, not the navigation view" "$line" "user_verification"
# next-step navigates past the boundary reset (review_security complete again for navigation).
mk_state '{"sid":"cg-c4n","path":"direct","upto":"pre_final_report_gate","steps":"user_verification=pending","uvReset":"post-push"}'
git -C "$RP_REPO" reset -q
nav="$(run_next_step cg-c4n)"
check "same state navigates to session-close" "$(field "$nav" NEXT_SKILL)" "session-close"
case_end

case_begin "worktree: user_verification / cleanup deferred-in-worktree" "hooks/workflow-gate/commit-gate-steps.js"
export ENFORCE_WORKTREE=on
rp_worktree
mk_state "{\"sid\":\"cg-wt\",\"path\":\"pull_request\",\"entered\":true,\"cwd\":\"$RP_WT_M\",\"upto\":\"review_security\",\"steps\":\"review_security=pending;push_branch=pending;user_verification=pending;deliver=pending;cleanup=pending\"}"
out="$(commit_in cg-wt "$RP_WT_M")"
line="$(first_line "$out")"
check_contains "canary present" "$line" "review_security"
check_not_contains "user_verification deferred in a worktree" "$line" "user_verification"
check_not_contains "cleanup deferred in a worktree" "$line" "cleanup"
case_end

case_begin "worktree pull_request: every prerequisite settled -> commit approved" "hooks/workflow-gate/commit-gate-steps.js"
mk_state "{\"sid\":\"cg-wt-ok\",\"path\":\"pull_request\",\"entered\":true,\"cwd\":\"$RP_WT_M\",\"upto\":\"push_branch\",\"steps\":\"push_branch=pending;user_verification=pending;deliver=pending;cleanup=pending\"}"
out="$(commit_in cg-wt-ok "$RP_WT_M")"
check "gate decision is approve" "$(hook_decision "$out")" "approve"
check_not_contains "no incomplete-steps list" "$out" "$LIST_HEAD"
case_end

case_begin "direct on main: user_verification complete, deliver pending -> commit approved" "hooks/workflow-gate/commit-gate-steps.js"
export ENFORCE_WORKTREE=off
git -C "$RP_REPO" reset -q
git -C "$RP_REPO" checkout -q main
mk_state '{"sid":"cg-main-ok","path":"direct","branch":"main","upto":"deliver","steps":"deliver=pending"}'
out="$(commit_in cg-main-ok "$RP_REPO_M")"
check "commit runs on main" "$(git -C "$RP_REPO" rev-parse --abbrev-ref HEAD)" "main"
check "gate decision is approve" "$(hook_decision "$out")" "approve"
check_not_contains "no incomplete-steps list" "$out" "$LIST_HEAD"
git -C "$RP_REPO" reset -q
git -C "$RP_REPO" checkout -q feature/2527-rp
export ENFORCE_WORKTREE=on
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit "$FAIL"
