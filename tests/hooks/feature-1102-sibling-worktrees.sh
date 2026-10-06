#!/bin/bash
# tests/hooks/feature-1102-sibling-worktrees.sh
# Tests: hooks/lib/worktree-notes.js, bin/worktree-write-notes.js
# Tags: worktree, sibling, security, scope:issue-specific
# Dispatcher for multi-repo SiblingWorktrees tests; sub-files live in feature-1102-sibling-worktrees/.
# L3 gap (what this test does NOT catch): CE2/CE3 capture-env.sh sibling PR resolution via gh;
# /worktree-start populating SIBLING_WORKTREES_JSON from intent.md; capture-env.sh reading
# SiblingWorktrees back from WORKTREE_NOTES.md; a real claude -p worktree-copy-worker run.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TESTS_DIR/../lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT
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
