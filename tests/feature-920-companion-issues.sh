#!/bin/bash
# tests/feature-920-companion-issues.sh
# Tests: bin/github-issues/find-companion-issues.sh, bin/github-issues/lib/companion-passes.sh, skills/workflow-init/SKILL.md, skills/clarify-intent/SKILL.md, .env.example
# Tags: companion-issues, workflow-init, clarify-intent, find-companion-issues, scope:issue-specific
#
# Dispatch + aggregate entrypoint for the feature-920-companion-issues split
# suite. All logic lives in tests/feature-920-companion-issues/ per
# rules/coding/file-split.md Pattern A. Each split group also runs standalone.
#
# L3 gap (what this test does NOT catch):
# - Whether workflow-init and clarify-intent invoke find-companion-issues.sh
#   at runtime in a live session, or whether AskUserQuestion fires correctly.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

SPLIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-920-companion-issues"

SPLIT_GROUPS=(
    "a-series.sh"
    "b-series.sh"
    "c-d-series.sh"
    "fc-series.sh"
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

    results_line="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed' "$out_file" | tail -1)"
    if [ -n "$results_line" ]; then
        g_pass="$(printf '%s' "$results_line" | sed -E 's/^Results: ([0-9]+) passed.*/\1/')"
        g_fail="$(printf '%s' "$results_line" | sed -E 's/.* ([0-9]+) failed.*/\1/')"
        TOTAL_PASS=$((TOTAL_PASS + g_pass))
        TOTAL_FAIL=$((TOTAL_FAIL + g_fail))
    else
        echo "WARN: $group emitted no Results line (exit=$rc); counting as 1 failure"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
    rm -f "$out_file"
done

echo ""
echo "═════════════════════════════════════════"
echo "Aggregate Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
