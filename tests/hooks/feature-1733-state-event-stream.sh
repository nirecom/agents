#!/bin/bash
# tests/hooks/feature-1733-state-event-stream.sh
# Tests: hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/lock.js, hooks/workflow-state/state-io/migrations/v1-to-v2.js
# Tags: workflow-state, event-stream, append-only, migration, concurrency, dispatcher, scope:issue-specific, pwsh-not-required, TL2, dup-group-keep:time-hard-limit, test-lang-exception:e2e
# #1733 append-only event-stream suite; split for per-file time: this file runs the core-model
# group, the feature-1733-state-event-stream-<group>.sh siblings the rest. Each sub-script owns
# its temp WORKFLOW_STATE_DIR, fixture AGENTS_MAIN_ROOT, WORKFLOW_PLANS_DIR and HOME. No skip
# path (common.sh header): the one 77 handled is the `command -v node` environment gate.
# TL3 gap: hooks are invoked directly, so a hook unwired from settings.json still passes;
# mitigation: hook-registration category in bin/check-verification-gate.sh.

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
case_begin "dispatch-sub-suites-core-model" "hooks/workflow-state/state-io/events.js"
# Core model: the append-only stream and the projection derived from it.
run_sub "events-append"
run_sub "event-vocabulary"
run_sub "projection-contract"
run_sub "projection-strip"
run_sub "annotation-fold"
run_sub "class-members-history"
run_sub "started-at-removed"
case_end

echo ""
if [ "$OVERALL" -eq 0 ]; then
    echo "feature-1733-state-event-stream: all sub-suites reported success"
else
    echo "feature-1733-state-event-stream: at least one sub-suite FAILED"
fi
exit "$OVERALL"
