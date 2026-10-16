#!/usr/bin/env bash
# tests/agents/feature-clarify-intent.sh
# Tests: agents/lib/triage-legacy-compat.md, skills/clarify-intent/SKILL.md, skills/clarify-intent/reference/aggregate-class-members.md, skills/clarify-intent/reference/class-members-proposal.md, skills/_shared/judge-decomposition.md, skills/clarify-intent/scripts/precheck-companions.sh
# Tags: workflow, clarify-intent, planning, intent, plans, scope:common
# L3 gap (what this test does NOT catch): whether clarify-intent behaves correctly in a live
#   claude -p session (static content assertions + mocked script behavior only).
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
#   bin/check-verification-gate.sh category: skill-orchestration.
# Dispatch + aggregate entrypoint; the groups live in tests/agents/feature-clarify-intent/
# (rules/coding/file-split.md Pattern A) and each also runs standalone.

# Timeout guard: if running without the sentinel, re-exec under timeout
if [ -z "${_TIMEOUT_WRAPPED:-}" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

set -uo pipefail

# CLARIFY_INTENT_SPLIT_DIR is a test seam only (tests/agents/feature-clarify-intent-aggregate.sh
# points it at fixture children); unset, the real split directory is used.
SPLIT_DIR="${CLARIFY_INTENT_SPLIT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-clarify-intent}"

SPLIT_GROUPS=(
    "static-series.sh"
    "companion-precheck-series.sh"
)

TOTAL_PASS=0
TOTAL_FAIL=0
RESULTS_SEEN=0
GROUP_RC_FAIL=0

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
    # A child's own exit status is authoritative: a crash after a "0 failed" line must not read green.
    if [ "$rc" -ne 0 ]; then
        echo "FAIL: $group exited $rc"
        GROUP_RC_FAIL=$((GROUP_RC_FAIL + 1))
    fi

    results_line="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed' "$out_file" | tail -1)"
    if [ -n "$results_line" ]; then
        RESULTS_SEEN=$((RESULTS_SEEN + 1))
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
echo "=== Summary ==="
echo "PASS: $TOTAL_PASS  FAIL: $TOTAL_FAIL  GROUP_RC_FAIL: $GROUP_RC_FAIL  RESULTS_SEEN: $RESULTS_SEEN"

# Exit status: non-zero on any failed assertion, any non-zero child, or no Results line at all.
[ "$TOTAL_FAIL" -eq 0 ] && [ "$GROUP_RC_FAIL" -eq 0 ] && [ "$RESULTS_SEEN" -gt 0 ]
