#!/bin/bash
# tests/feature-1102-sibling-worktrees.sh
# Tests: hooks/lib/worktree-notes.js, bin/worktree-write-notes.js
# Tags: worktree, sibling, security, scope:issue-specific
#
# Dispatcher for multi-repo SiblingWorktrees feature tests.
# Sub-files: lib-tests.sh (SW1-4, SW-Idm1, SW-Sec1-4), cli-tests.sh (SW-CLI1-3)
#
# L3 gap (what this test does NOT catch):
# - CE2/CE3: non-bootstrap capture-env.sh normal mode with sibling repo PR resolution via gh
# - Real multi-repo session integration where /worktree-start populates SIBLING_WORKTREES_JSON from intent.md
# - End-to-end verification that capture-env.sh reads back SiblingWorktrees from WORKTREE_NOTES.md
# - Real claude -p session verifying ## SiblingWorktrees appears in worktree-copy-worker output
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0

run_sub() {
    local out; out="$(bash "$1" 2>&1)"
    printf '%s\n' "$out"
    local p f
    p=$(printf '%s\n' "$out" | grep -c '^PASS:' || true)
    f=$(printf '%s\n' "$out" | grep -c '^FAIL:' || true)
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
}

run_sub "$TESTS_DIR/feature-1102-sibling-worktrees/lib-tests.sh"
run_sub "$TESTS_DIR/feature-1102-sibling-worktrees/lib-security-tests.sh"
run_sub "$TESTS_DIR/feature-1102-sibling-worktrees/cli-tests.sh"
run_sub "$TESTS_DIR/feature-1102-sibling-worktrees/cli-validation-tests.sh"

echo ""
echo "Total: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL"
exit $TOTAL_FAIL
