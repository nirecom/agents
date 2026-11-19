#!/bin/bash
# tests/hooks/feature-1733-state-event-stream-final-report-robustness.sh
# Tests: hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/lock.js, hooks/workflow-state/state-io/migrations/v1-to-v2.js
# Tags: workflow-state, event-stream, append-only, migration, concurrency, dispatcher, scope:issue-specific, pwsh-not-required, TL2, dup-group-keep:time-hard-limit, test-lang-exception:e2e
#
# One of the feature-1733-state-event-stream*.sh dispatchers, split for per-file test time.
# Each runs its share of the sub-suites in tests/hooks/feature-1733-state-event-stream/;
# the suite contract (no skip path, the single exit-77 node gate, the TL3 gap) is in the
# header of tests/hooks/feature-1733-state-event-stream.sh.
# This file: the final_report consumer and the adversarial-input robustness suite.

set -u
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE="$SCRIPT_DIR/feature-1733-state-event-stream"

OVERALL=0

run_sub() {
    local name="$1"
    echo ""
    echo "=== $name ==="
    bash "$SUITE/$name.sh"
    local rc=$?
    # 77 has exactly one source: common.sh's `command -v node` gate. Case files exit
    # 0/1 only (see finish()), so 77 can never mean "n failures".
    if [ "$rc" -eq 77 ]; then
        echo "(skipped: $name found no node interpreter — environment gate, not a feature probe)"
        return 0
    fi
    [ "$rc" -ne 0 ] && OVERALL=1
    return "$rc"
}

# The sub-suites run as child processes, so this dispatch case observes no assertion of its own.
case_begin "dispatch-sub-suites-final-report-robustness" "hooks/workflow-state/state-io/events.js"
# Per-consumer behaviours built on the stream.
run_sub "final-report-step"

# Adversarial / malformed input and collection boundaries.
run_sub "robustness"
case_end

echo ""
if [ "$OVERALL" -eq 0 ]; then
    echo "feature-1733-state-event-stream-final-report-robustness: all sub-suites reported success"
else
    echo "feature-1733-state-event-stream-final-report-robustness: at least one sub-suite FAILED"
fi
exit "$OVERALL"
