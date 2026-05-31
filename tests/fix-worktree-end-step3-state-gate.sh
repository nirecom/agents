#!/bin/bash
# tests/fix-worktree-end-step3-state-gate.sh
# Tests: skills/worktree-end/SKILL.md
# Tags: worktree-end-step3-state-gate
#
# Tests for the PR state gate added to /worktree-end Step 3 (issue #358).
# The state gate applies to both AUTO_MERGE_PR=on and off modes (runs before the split).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# D11 — SKILL.md Step 3 PR state gate contract
# RED before commit 2: none of these strings exist in current SKILL.md Step 3
# GREEN after commit 2: Step 3 state gate is added
D11_step3_state_gate_contract() {
    local skill="$AGENTS_DIR/skills/worktree-end/SKILL.md"

    # D11a: exact gh command for state gate
    # (Step 3a uses `gh pr view "$PR_NUMBER" --json state` without --jq .state)
    grep -qF 'gh pr view "$PR_NUMBER" --json state --jq .state' "$skill" \
        && pass "D11a step3_has_state_gate_command" \
        || fail "D11a step3_has_state_gate_command: exact state gate gh command not found"

    # D11b: backtick-delimited MERGED routing
    # (Step 3a uses prose "MERGED" without backticks → no false match)
    grep -qF '`MERGED` → step 3b' "$skill" \
        && pass "D11b step3_merged_routes_to_3b" \
        || fail "D11b step3_merged_routes_to_3b: \`MERGED\` → step 3b routing not found"

    # D11c: CLOSED state surfaces explicit error (not silent fall-through)
    grep -qF 'was closed without merging' "$skill" \
        && pass "D11c step3_closed_surfaces_error" \
        || fail "D11c step3_closed_surfaces_error: CLOSED error text not found"

    # D11d: fail-closed on error/empty/unexpected state
    grep -qF 'Unable to determine' "$skill" \
        && pass "D11d step3_failclosed_unknown" \
        || fail "D11d step3_failclosed_unknown: fail-closed on error/unknown not found"
}

D11_step3_state_gate_contract

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
