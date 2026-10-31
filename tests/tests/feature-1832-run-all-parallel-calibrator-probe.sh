#!/bin/bash
# tests/tests/feature-1832-run-all-parallel-calibrator-probe.sh — #1832 parallel-runner suite: calibrator probe, signal cleanup.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, split-group, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests
# One split group of the former feature-1832-run-all-parallel.sh dispatcher (#2723); runner: feature-1832-run-all-parallel/_entry.sh.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-1832-run-all-parallel/_entry.sh"
case_begin "calibrator-probe" "bin/calibrate-test-parallelism.sh"
f1832_run g6-calibrator-probe.sh j-signal-cleanup.sh j2-signal-timed-exec.sh
case_end
[ "$FAIL" -eq 0 ]
