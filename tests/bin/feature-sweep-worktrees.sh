#!/bin/bash
# tests/feature-sweep-worktrees.sh
# Tests: bin/sweep-worktrees.sh
# Tags: sweep, worktree, maintenance, bin, git
#
# Dispatch + re-export entrypoint for the feature-sweep-worktrees split suite.
# All logic lives in tests/feature-sweep-worktrees/ per rules/coding/file-split.md
# Pattern A. This file runs each split group as a subprocess, forwards its
# output, parses its `Results: N passed, M failed` line, and prints a final
# aggregate. Each split group also runs standalone.

set -uo pipefail

SPLIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-sweep-worktrees"

SPLIT_GROUPS=(
    "registry.sh"
    "orphan.sh"
    "gh-stub.sh"
    "empty-parent.sh"
    "validation.sh"
)

TOTAL_PASS=0
TOTAL_FAIL=0

for group in "${SPLIT_GROUPS[@]}"; do
    script="$SPLIT_DIR/$group"
    if [ ! -f "$script" ]; then
        echo "FAIL: split group missing: $script"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        continue
    fi

    echo ""
    echo "═══ $group ═══"
    out_file="$(mktemp)"
    bash "$script" 2>&1 | tee "$out_file"
    rc=${PIPESTATUS[0]}

    # Parse "Results: N passed, M failed" line emitted by each split file.
    results_line="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed' "$out_file" | tail -1)"
    if [ -n "$results_line" ]; then
        g_pass="$(printf '%s' "$results_line" | sed -E 's/^Results: ([0-9]+) passed.*/\1/')"
        g_fail="$(printf '%s' "$results_line" | sed -E 's/.* ([0-9]+) failed.*/\1/')"
        TOTAL_PASS=$((TOTAL_PASS + g_pass))
        TOTAL_FAIL=$((TOTAL_FAIL + g_fail))
    else
        # No Results line emitted (group crashed) — count exit code as 1 failure.
        echo "WARN: $group emitted no Results line (exit=$rc); counting as 1 failure"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
    rm -f "$out_file"
done

echo ""
echo "═════════════════════════════════════════"
echo "Aggregate Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
