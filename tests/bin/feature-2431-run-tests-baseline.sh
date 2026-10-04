#!/usr/bin/env bash
# tests/bin/feature-2431-run-tests-baseline.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-ledger.sh, bin/lib/run-tests-baseline-worktree.sh, bin/lib/run-tests-baseline-exec.sh, hooks/lib/baseline-checkout-marker.js
# Tags: run-tests, baseline, ledger, worktree, exec, scope:issue-specific, pwsh-not-required, TL2
#
# TDD — all tests are RED until stage-6 / stage-7 implementation lands.
# Dispatcher: case groups in feature-2431-run-tests-baseline/ part files.
#
# TL3 gap: whether a real session's worker path seeds failing_tests correctly
# is tested by tests/hooks/feature-2431-run-tests-failing-list.sh.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

SUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-2431-run-tests-baseline"

# shellcheck source=./feature-2431-run-tests-baseline/helpers.sh
. "$SUBDIR/helpers.sh"
# shellcheck source=./feature-2431-run-tests-baseline/ledger.sh
. "$SUBDIR/ledger.sh"
# shellcheck source=./feature-2431-run-tests-baseline/inherit-reject.sh
. "$SUBDIR/inherit-reject.sh"
# shellcheck source=./feature-2431-run-tests-baseline/worktree.sh
. "$SUBDIR/worktree.sh"
# shellcheck source=./feature-2431-run-tests-baseline/exec.sh
. "$SUBDIR/exec.sh"
# shellcheck source=./feature-2431-run-tests-baseline/cli.sh
. "$SUBDIR/cli.sh"
# shellcheck source=./feature-2431-run-tests-baseline/cli-unsupported.sh
. "$SUBDIR/cli-unsupported.sh"

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

case_begin "baseline-exec" "bin/lib/run-tests-baseline-exec.sh"
run_exec_cases
case_end

case_begin "baseline-exec-isolation" "bin/lib/run-tests-baseline-exec.sh"
run_exec_isolation_cases
case_end

case_begin "baseline-cli" "bin/run-tests-baseline"
run_cli_cases
case_end

case_begin "baseline-cli-missing-at-base" "bin/run-tests-baseline"
run_cli_missing_at_base_cases
case_end

case_begin "baseline-cli-undetermined" "bin/run-tests-baseline"
run_cli_undetermined_cases
case_end

case_begin "baseline-cli-ambiguous-exit" "bin/run-tests-baseline"
run_cli_ambiguous_exit_cases
case_end

case_begin "baseline-cli-exec-setup-failed" "bin/run-tests-baseline"
run_cli_exec_setup_failed_cases
case_end

case_begin "baseline-cli-unsupported-at-base" "bin/run-tests-baseline"
run_cli_unsupported_at_base_cases
case_end

case_begin "baseline-cli-same-base-pass-cached" "bin/run-tests-baseline"
run_cli_same_base_pass_cases
case_end

case_begin "baseline-ledger-inherit-reject" "bin/run-tests-baseline"
run_ledger_inherit_reject_cases
case_end

case_begin "baseline-ledger-inherit-literal-glob" "bin/run-tests-baseline"
run_ledger_inherit_glob_cases
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
