#!/bin/bash
# tests/feature-worktree-write-notes.sh
# Tests: hooks/lib/worktree-notes.js, bin/worktree-write-notes.js
# Tags: worktree, notes, security, scope:common
#
# Dispatcher — sub-files: normal-lib-write.sh, normal-lib-run.sh,
#   normal-cli.sh, security.sh, error.sh, sibling-notes.sh
#
# L3 gap (what this test does NOT catch):
# - Real worktree-start session populating ## SiblingWorktrees via intent.md probe
# - End-to-end multi-repo flow through worktree-copy-worker Step 3b
# Covered by tests/feature-1102-sibling-worktrees.sh at the CLI boundary.

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

run_sub "$TESTS_DIR/feature-worktree-write-notes/normal-lib-write.sh"
run_sub "$TESTS_DIR/feature-worktree-write-notes/normal-lib-run.sh"
run_sub "$TESTS_DIR/feature-worktree-write-notes/normal-cli.sh"
run_sub "$TESTS_DIR/feature-worktree-write-notes/security.sh"
run_sub "$TESTS_DIR/feature-worktree-write-notes/error.sh"
run_sub "$TESTS_DIR/feature-worktree-write-notes/sibling-notes.sh"

echo ""
echo "Total: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL"
exit $TOTAL_FAIL
