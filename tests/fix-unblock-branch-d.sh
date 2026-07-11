#!/bin/bash
# tests/fix-unblock-branch-d.sh
# Tests: hooks/enforce-worktree.js, hooks/lib/bash-write-patterns.js, hooks/lib/command-parser.js, hooks/enforce-worktree/branch-delete-guard.js
# Tags: worktree, enforce, hook, branch-delete, redirect, scope:common
#
# Dispatcher only — all test bodies live in tests/fix-unblock-branch-d/.
# Shared helpers / fixtures live in tests/fix-unblock-branch-d/_lib.sh.
# See file-split.md Pattern A: this entrypoint is dispatch + aggregate only.
#
# Each split group is runnable standalone, e.g.:
#   bash tests/fix-unblock-branch-d/unit.sh
# The dispatcher runs each group as a child bash process and aggregates the
# "Results: N passed, M failed" line each emits, plus exit codes.

set -uo pipefail

DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/fix-unblock-branch-d" && pwd)"

TEST_GROUPS=(unit integration hook-redirect)

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_GROUPS=()

for group in "${TEST_GROUPS[@]}"; do
    out="$(bash "$DISPATCH_DIR/$group.sh" 2>&1)"
    rc=$?
    echo "$out"

    # Parse "Results: N passed, M failed" emitted by each split file.
    line="$(printf '%s\n' "$out" | grep -E '^Results: [0-9]+ passed, [0-9]+ failed' | tail -1)"
    if [ -n "$line" ]; then
        p="$(printf '%s' "$line" | sed -E 's/^Results: ([0-9]+) passed.*/\1/')"
        f="$(printf '%s' "$line" | sed -E 's/^Results: [0-9]+ passed, ([0-9]+) failed.*/\1/')"
        TOTAL_PASS=$((TOTAL_PASS + p))
        TOTAL_FAIL=$((TOTAL_FAIL + f))
    fi

    if [ "$rc" -ne 0 ]; then
        FAILED_GROUPS+=("$group")
    fi
done

echo ""
echo "═════════════════════════════════════════"
echo "Aggregate: $TOTAL_PASS passed, $TOTAL_FAIL failed"
if [ "${#FAILED_GROUPS[@]}" -gt 0 ]; then
    echo "Failed groups: ${FAILED_GROUPS[*]}"
    exit 1
fi
exit 0
