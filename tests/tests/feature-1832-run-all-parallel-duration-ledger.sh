#!/bin/bash
# tests/tests/feature-1832-run-all-parallel-duration-ledger.sh — #1832 parallel-runner suite: duration ledger (n*) and phase gating.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, split-group, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests
# One split group of the former feature-1832-run-all-parallel.sh dispatcher (#2723); runner: feature-1832-run-all-parallel/_entry.sh.
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-1832-run-all-parallel/_entry.sh"
case_begin "duration-ledger" "tests/run-all.sh"
f1832_run n-duration-ledger.sh n-phase-gating.sh n2-duration-ledger-order.sh n3-duration-ledger-reader.sh n4-duration-ledger-worktree.sh n5-duration-ledger-runtime.sh n6-duration-ledger-format.sh n7-duration-ledger-bounds.sh n8-duration-ledger-keyspace.sh n9-duration-ledger-env.sh n10-duration-ledger-deadline.sh n11-duration-ledger-ownership.sh n12-duration-ledger-recency.sh n13-duration-ledger-default-home.sh n14-duration-ledger-host-scope.sh n15-duration-ledger-generation.sh
case_end
[ "$FAIL" -eq 0 ]
