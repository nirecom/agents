#!/usr/bin/env bash
# tests/feature-1113-1058-check-issues-class-coverage.sh
# Tests: bin/check-issues-class-coverage, skills/_shared/assemble-mandatory.sh
# Tags: scope:issue-specific
# Dispatcher for bin/check-issues-class-coverage contract tests.
# Sub-files in the sibling directory handle outline, detail, and assemble modes.
#
# L3 gap (what this test does NOT catch):
# - Gate 2 firing correctly in the real make-detail-plan MDP-7 auto-advance path (CONFIRM_DETAIL=off)
# - PLAN_LANG-variant heading detection for ## Steps / ## Files to modify in non-English plans
# Closest-to-action mitigation: gap checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF_DIR="$AGENTS_ROOT/tests/feature-1113-1058-check-issues-class-coverage"

TOTAL_PASS=0
TOTAL_FAIL=0

for sub in outline detail assemble; do
    echo ""
    echo "=== $sub tests ==="
    sub_out=$(bash "$SELF_DIR/$sub.sh" 2>&1)
    echo "$sub_out"
    results_line=$(echo "$sub_out" | grep "^Results:")
    p=$(echo "$results_line" | awk '{split($2, a, "/"); print a[1]+0}')
    f=$(echo "$results_line" | awk '{print $4+0}')
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))
done

echo ""
TOTAL=$((TOTAL_PASS + TOTAL_FAIL))
echo "Results: $TOTAL_PASS/$TOTAL passed, $TOTAL_FAIL failed"
if [[ $TOTAL_FAIL -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$TOTAL_FAIL test(s) failed."
    exit 1
fi
