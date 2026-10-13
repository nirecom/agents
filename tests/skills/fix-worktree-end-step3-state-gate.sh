#!/bin/bash
# tests/skills/fix-worktree-end-step3-state-gate.sh
# Tests: skills/worktree-end/SKILL.md, skills/merge-to-main/SKILL.md
# Tags: worktree, end, cleanup, skill, bin, scope:issue-specific, deliver, merge-to-main
#
# Tests for the PR state gate added to /worktree-end Step 3 (issue #358).
# #2527 moved the merge and its PR state gate to /merge-to-main MM-3 (bin/workflow/pr-state).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# D11 — /merge-to-main MM-3 PR state gate contract (was worktree-end Step 3)
D11_step3_state_gate_contract() {
    local skill="$SCRIPT_CHECKOUT_ROOT/skills/merge-to-main/SKILL.md"

    # D11a: the state gate reads PR_STATE from the pr-state CLI
    grep -qF 'bin/workflow/pr-state"` and read `PR_STATE=`' "$skill" \
        && pass "D11a step3_has_state_gate_command" \
        || fail "D11a step3_has_state_gate_command: MM-3 pr-state gate command not found"

    # D11b: backtick-delimited MERGED routes to step completion without re-merging
    grep -qF '`MERGED` → already delivered; go to MM-5' "$skill" \
        && pass "D11b step3_merged_routes_to_completion" \
        || fail "D11b step3_merged_routes_to_completion: \`MERGED\` → MM-5 routing not found"

    # D11c + D11d: CLOSED surfaces an explicit stop; UNKNOWN fails closed (same line)
    grep -qF '`CLOSED` or `UNKNOWN` → surface the state and stop' "$skill" \
        && pass "D11c step3_closed_surfaces_error" \
        || fail "D11c step3_closed_surfaces_error: CLOSED stop text not found"
    grep -qF '`UNKNOWN` → surface the state and stop' "$skill" \
        && pass "D11d step3_failclosed_unknown" \
        || fail "D11d step3_failclosed_unknown: fail-closed on UNKNOWN not found"

    # D11e: worktree-end no longer merges (the gate must not be duplicated there)
    grep -qE 'gh pr merge|glab mr merge' "$SCRIPT_CHECKOUT_ROOT/skills/worktree-end/SKILL.md" \
        && fail "D11e worktree_end_no_merge: worktree-end still issues a merge command" \
        || pass "D11e worktree_end_no_merge"
}

D11_step3_state_gate_contract

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
