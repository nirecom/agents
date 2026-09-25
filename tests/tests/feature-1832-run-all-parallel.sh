#!/usr/bin/env bash
# tests/tests/feature-1832-run-all-parallel.sh — dispatcher for the #1832 parallel-runner suite.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, scope:issue-specific
# Serial: timing-sensitive parallelism measurements must not compete with other tests
#
# Cases discovered by glob from tests/tests/feature-1832-run-all-parallel/<dir>/*.sh.
# Child output piped through contract mask to prevent RUN_CONTRACT: line forgery
# (hooks/workflow-run-tests.js one-contract-line rule).

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CASE_DIR="$AGENTS_DIR/tests/tests/feature-1832-run-all-parallel"
CASE_TIMEOUT="${FEATURE_1832_CASE_TIMEOUT:-300}"

PASSED=0
FAILED=0
SKIPPED=0
FAILED_CASES=""

run_with_timeout() { "$AGENTS_DIR/bin/run-with-timeout.sh" "$@"; }
mask_contract() { sed 's/^\([[:blank:]]*\)RUN_CONTRACT:/\1[masked] RUN_CONTRACT:/'; }

if [ ! -d "$CASE_DIR" ]; then
    echo "FAIL: case directory missing: $CASE_DIR"
    exit 1
fi

shopt -s nullglob
for case_file in "$CASE_DIR"/*.sh; do
    case_name="$(basename "$case_file")"
    case "$case_name" in
        _*) continue ;;
    esac

    echo ""
    echo "########## $case_name ##########"
    # No `|| true` here: it would overwrite PIPESTATUS and hide every failure.
    run_with_timeout "$CASE_TIMEOUT" bash "$case_file" 2>&1 | mask_contract
    rc=${PIPESTATUS[0]}

    if [ "$rc" -eq 0 ]; then
        PASSED=$((PASSED + 1))
    elif [ "$rc" -eq 77 ]; then
        SKIPPED=$((SKIPPED + 1))
        echo "SKIP: $case_name"
    else
        FAILED=$((FAILED + 1))
        FAILED_CASES="$FAILED_CASES $case_name(exit $rc)"
    fi
done

echo ""
echo "=== feature-1832 dispatcher: pass=$PASSED fail=$FAILED skip=$SKIPPED ==="
if [ "$FAILED" -ne 0 ]; then
    echo "failed cases:$FAILED_CASES"
    exit 1
fi
exit 0
