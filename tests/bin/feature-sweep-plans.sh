#!/bin/bash
# tests/feature-sweep-plans.sh
# Tests: bin/sweep-plans.sh, skills/sweep-plans/SKILL.md
# Tags: sweep, plans, workflow-plans, maintenance, bin, scope:common
#
# Dispatcher only (file-split.md Pattern A) — test bodies + shared helpers
# live in tests/feature-sweep-plans/; each group runs standalone too, e.g.
# bash tests/feature-sweep-plans/core.sh. Aggregates each group's exit code
# and "Results: N passed, M failed" line.

set -uo pipefail

DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/feature-sweep-plans" && pwd)"

TEST_GROUPS=(core validation)

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_GROUPS=()

for group in "${TEST_GROUPS[@]}"; do
    out="$(bash "$DISPATCH_DIR/$group.sh" 2>&1)"
    rc=$?
    echo "$out"

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
