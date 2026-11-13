#!/usr/bin/env bash
# tests/bin/feature-2956-baseline-compare-cli.sh
# Tests: bin/run-tests-baseline
# Tags: run-tests, baseline, cli, compare, fail-details, scope:issue-specific, pwsh-not-required, TL2
# #2956 S4/S8, four of the outline's five shapes in one CLI run (one base worktree): a violation
# added, only a count shrinking, a fully listed list shrinking, a list short of its total shrinking.
# The fifth (a changed test file) runs in -closed to keep each file under the time budget.
# Fixture and helpers: feature-2956-baseline-compare-cli/_lib.sh. Sibling entrypoints: -closed
# (fail-closed shapes), -missing (one side missing, rename, normalization), -gates (rtb_test_changed
# and the bootstrap exit 5).

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=./feature-2431-run-tests-baseline/_cache.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_cache.sh"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=./feature-2956-baseline-compare-cli/_lib.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2956-baseline-compare-cli/_lib.sh"

cmp_run outline addv count list cutlist

case_begin "compare-cli-violation-added" "bin/run-tests-baseline"
cmp_expect_new "S1: one more violation on the branch is (c) new=1" addv "violation Y"
case_end

case_begin "compare-cli-count-shrinks" "bin/run-tests-baseline"
cmp_expect_pre "S2: only a [count=N] shrinking is preexisting" count
case_end

case_begin "compare-cli-full-list-shrinks" "bin/run-tests-baseline"
cmp_expect_pre "S3: a fully listed [list total=M] shrinking is preexisting" list
case_end

case_begin "compare-cli-cut-list-shrinks" "bin/run-tests-baseline"
cmp_expect_new "S4: a list whose items fall short of total= shrinking is (c)" cutlist "total=4"
cmp_expect_summary "summary: preexisting=2 new_on_branch=2, exit 1 (pending (c) lines)" 1 2 0 2
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
