#!/bin/bash
# tests/feature-feat-928-supervisor-report-format.sh
# Tests: hooks/lib/supervisor-report-format.js (formatter module) + supervisor-guard.js integration
# Tags: supervisor, em-supervisor, layer2, hook, stop, format, display

# L3 gap (what this test suite does NOT catch):
#   - Whether supervisor-guard.js is registered as a Stop hook in settings.json
#   - Whether the hook fires in the real Claude Code session environment
# Closest-to-action mitigation: bin/check-verification-gate.sh (hook-registration)
#   fires an AskUserQuestion at WORKFLOW_USER_VERIFIED preflight.
#
# Dispatcher only — all test bodies live in tests/feature-feat-928-supervisor-report-format/.
# Shared helpers / fixtures live in tests/feature-feat-928-supervisor-report-format/_lib.sh.
# See file-split.md Pattern A: this entrypoint is dispatch + aggregate only.
#
# Each split group is runnable standalone, e.g.:
#   bash tests/feature-feat-928-supervisor-report-format/formatter-unit.sh
# The dispatcher runs both groups and aggregates exit codes + the
# "Results: N passed, M failed" line each emits.

set -uo pipefail

DISPATCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/feature-feat-928-supervisor-report-format" && pwd)"

TEST_GROUPS=(formatter-unit guard-integration)

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
