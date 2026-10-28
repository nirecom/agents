#!/bin/bash
# tests/tests/feature-1832-run-all-parallel-cache-jobs.sh — #1832 parallel-runner suite: jobs surface, cache, dispatcher jobs, deadline.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, split-group, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests
# One split group of the former feature-1832-run-all-parallel.sh dispatcher (#2723); runner: feature-1832-run-all-parallel/_entry.sh.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-1832-run-all-parallel/_entry.sh"
case_begin "cache-jobs" "tests/run-all.sh"
f1832_run d-jobs-surface.sh f-cache.sh f2-cache-boundaries.sh k-dispatcher-jobs.sh l-deadline.sh
case_end
[ "$FAIL" -eq 0 ]
