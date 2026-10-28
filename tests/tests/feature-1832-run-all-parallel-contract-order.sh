#!/bin/bash
# tests/tests/feature-1832-run-all-parallel-contract-order.sh — #1832 parallel-runner suite: contract, order, serial barrier, serial header, hook integration.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, split-group, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests
# One split group of the former feature-1832-run-all-parallel.sh dispatcher (#2723); runner: feature-1832-run-all-parallel/_entry.sh.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-1832-run-all-parallel/_entry.sh"
case_begin "contract-order" "tests/run-all.sh"
f1832_run a-contract-and-exit.sh a2-contract-neutralization.sh b-order-determinism.sh c-serial-barrier.sh e-reap-fallback.sh h-serial-header-convention.sh h2-serial-header-boundaries.sh h3-serial-comment-prefix.sh i-hook-contract-integration.sh
case_end
[ "$FAIL" -eq 0 ]
