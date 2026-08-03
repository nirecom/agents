#!/bin/bash
# tests/feature-1733-state-event-stream.sh
# Tests: hooks/workflow-state/state-io/events.js, hooks/workflow-state/state-io/projection.js, hooks/workflow-state/state-io/lock.js, hooks/workflow-state/state-io/migrations/v1-to-v2.js
# Tags: workflow-state, event-stream, append-only, migration, concurrency, dispatcher, scope:issue-specific, pwsh-not-required, TL2
#
# Dispatcher for the #1733 append-only event-stream suite. The state file changes from a
# keyed steps map (overwrite semantics) to events[] + a derived `current` projection, so
# the cases are grouped by the invariant they defend rather than by module: append-only,
# projection contract, concurrency/locking, v1->v2 migration, and the per-consumer
# behaviours (reset, worktree, inheritance, intervals, provenance, final_report).
#
# Each sub-script is self-contained: its own temp CLAUDE_WORKFLOW_DIR, its own fixture
# AGENTS_CONFIG_DIR, and its own temp WORKFLOW_PLANS_DIR / HOME.
#
# NO SKIP PATH: this suite is written test-first, so until the #1733 implementation
# lands every sub-suite is EXPECTED to fail and this dispatcher is expected to exit 1.
# A green run with nothing implemented would be the real defect — see the
# pre-implementation contract at the top of common.sh. The single 77 handled below is
# the `command -v node` environment gate, never a feature probe.
#
# TL3 gap (what this suite does NOT catch):
# - hook registration in settings.json: every hook here is invoked directly (module call
#   or JSON on stdin), so a hook that stops being wired still passes.
# Closest-to-action mitigation: hook-registration category in bin/check-verification-gate.sh.

set -u

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

# Core model: the append-only stream and the projection derived from it.
run_sub "events-append"
run_sub "event-vocabulary"
run_sub "projection-contract"
run_sub "projection-strip"
run_sub "annotation-fold"
run_sub "class-members-history"
run_sub "started-at-removed"

# Concurrency and locking — the plan's highest-risk area.
run_sub "concurrency"
run_sub "migration-concurrency"
run_sub "cleanup-stale"

# v1 -> v2 lazy migration.
run_sub "migration-v1-v2"
run_sub "migration-annotations"

# Per-consumer behaviours built on the stream.
run_sub "provenance"
run_sub "reset-from"
run_sub "worktree-event"
run_sub "session-inherit"
run_sub "final-report-step"
run_sub "intervals"

# Adversarial / malformed input and collection boundaries.
run_sub "robustness"

echo ""
if [ "$OVERALL" -eq 0 ]; then
    echo "feature-1733-state-event-stream: all sub-suites reported success"
else
    echo "feature-1733-state-event-stream: at least one sub-suite FAILED"
fi
exit "$OVERALL"
