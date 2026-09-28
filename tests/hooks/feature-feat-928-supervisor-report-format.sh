#!/bin/bash
# tests/hooks/feature-feat-928-supervisor-report-format.sh
# Tests: hooks/lib/supervisor-report-format.js
# Tags: supervisor, em-supervisor, layer2, hook, stop, format, display
# L3 gap: settings.json Stop registration and real-session firing of supervisor-guard.js;
#   mitigation: bin/check-verification-gate.sh (hook-registration) at WORKFLOW_USER_VERIFIED.
# Dispatcher only (file-split.md Pattern A): bodies + _lib.sh live in the sibling
#   feature-feat-928-supervisor-report-format/ dir; each group runs standalone and
#   emits "Results: N passed, M failed", which this entrypoint aggregates.

set -uo pipefail

DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/feature-feat-928-supervisor-report-format" && pwd)"

TEST_GROUPS=(formatter-unit guard-integration model-line)

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
