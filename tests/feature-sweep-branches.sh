#!/bin/bash
# tests/feature-sweep-branches.sh
# Tests: bin/sweep-branches.sh, hooks/enforce-worktree/branch-delete-guard.js
# Tags: sweep, branch, maintenance, bin, git, remote, scope:common
#
# Dispatcher only (file-split.md Pattern A) — test bodies + shared helpers
# live in tests/feature-sweep-branches/; each group runs standalone too, e.g.
# bash tests/feature-sweep-branches/core.sh. Aggregates each group's exit
# code and "Results: N passed, M failed" line.

set -uo pipefail

DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/feature-sweep-branches" && pwd)"

TEST_GROUPS=(core validation remote no-pr pr-state)

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
