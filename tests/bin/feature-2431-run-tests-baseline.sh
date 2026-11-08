#!/usr/bin/env bash
# tests/bin/feature-2431-run-tests-baseline.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-ledger.sh, bin/lib/run-tests-baseline-worktree.sh, hooks/lib/baseline-checkout-marker.js
# Tags: run-tests, baseline, ledger, worktree, stage-order, scope:issue-specific, pwsh-not-required, TL2
#
# One split group of the run-tests-baseline suite: ledger, worktree and stage-order cases.
# The sibling entrypoints tests/bin/feature-2431-run-tests-baseline-*.sh hold the other groups, so
# run-all runs them in parallel; preamble and parts: feature-2431-run-tests-baseline/_entry.sh.
#
# TL3 gap: whether a real session's worker path seeds failing_tests correctly
# is tested by tests/hooks/feature-2431-run-tests-failing-list.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=./feature-2431-run-tests-baseline/_cache.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_cache.sh"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=./feature-2431-run-tests-baseline/_entry.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_entry.sh"

case_begin "baseline-ledger" "bin/lib/run-tests-baseline-ledger.sh"
run_ledger_cases
case_end

case_begin "baseline-ledger-inherit" "bin/run-tests-baseline"
run_ledger_inherit_cases
case_end

case_begin "baseline-ledger-prune" "bin/lib/run-tests-baseline-ledger.sh"
run_ledger_prune_cases
case_end

case_begin "baseline-ledger-retention-boundary" "bin/lib/run-tests-baseline-ledger.sh"
run_ledger_boundary_cases
case_end

case_begin "baseline-ledger-segment-cap" "bin/lib/run-tests-baseline-ledger.sh"
run_ledger_segment_cap_cases
case_end

case_begin "baseline-worktree" "bin/lib/run-tests-baseline-worktree.sh"
run_worktree_cases
case_end

case_begin "baseline-worktree-guard" "bin/lib/run-tests-baseline-worktree.sh"
run_worktree_guard_cases
case_end

case_begin "baseline-cli-stage-order-and-rerun-request" "bin/run-tests-baseline"
run_cli_stage_order_cases
case_end

rtb_entry_finish
