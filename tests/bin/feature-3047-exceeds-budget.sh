#!/usr/bin/env bash
# tests/bin/feature-3047-exceeds-budget.sh
# Tests: bin/lib/run-tests-baseline-timeout.sh, bin/lib/run-tests-baseline-branch.sh, bin/lib/run-tests-baseline-classify.sh, bin/run-tests-baseline
# Tags: run-tests, baseline, timeout, budget, ledger, cli, scope:issue-specific, pwsh-not-required, TL2
# #3047: a failing test whose newest duration-ledger row is a completed run longer than the stage's
# per-call limit (branch 403 s, base 553 s) settles as `exceeds-budget` (auto) instead of looping on
# budget-exhausted; a timeout-only, shadowed, unmeasured or within-limit test stays budget-exhausted.
# The helper reads only what rtb_timeout_load_ledger read at the call's start (T1), the CLI never
# writes the duration ledger (T2), and the limit follows RTB_BUDGET_TOTAL, not elapsed time (T4).
# TL3 gap: no real 750 s test is run; the elapsed-time seams (TR_ADVANCE, SECONDS) reach budget 0.
# Case bodies: feature-3047-exceeds-budget/{unit,branch,base,cli}.sh; setup: _lib.sh, driver.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=./feature-2431-run-tests-baseline/_cache.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2431-run-tests-baseline/_cache.sh"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
harness_isolate "$(make_tmp)"
EB_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-3047-exceeds-budget"
# shellcheck source=./feature-3047-exceeds-budget/_lib.sh
. "$EB_DIR/_lib.sh"
# shellcheck source=./feature-3047-exceeds-budget/unit.sh
. "$EB_DIR/unit.sh"
# shellcheck source=./feature-3047-exceeds-budget/branch.sh
. "$EB_DIR/branch.sh"
# shellcheck source=./feature-3047-exceeds-budget/base.sh
. "$EB_DIR/base.sh"
# shellcheck source=./feature-3047-exceeds-budget/cli.sh
. "$EB_DIR/cli.sh"

EB_REPO="$TMPROOT/repo-drv"
eb_repo "$EB_REPO"
eb_unit_probe

case_begin "settle-branch-limit-403" "bin/lib/run-tests-baseline-timeout.sh"
eb_unit_branch_limit
case_end

case_begin "settle-keeps-applied-out" "bin/lib/run-tests-baseline-timeout.sh"
eb_unit_applied_kept
case_end

case_begin "settle-base-limit-553" "bin/lib/run-tests-baseline-timeout.sh"
eb_unit_base_limit
case_end

case_begin "settle-not-completed-terminations" "bin/lib/run-tests-baseline-timeout.sh"
eb_unit_not_completed
case_end

case_begin "settle-unmeasured" "bin/lib/run-tests-baseline-timeout.sh"
eb_unit_unmeasured
case_end

case_begin "settle-limit-follows-budget-total-seam" "bin/lib/run-tests-baseline-timeout.sh"
eb_unit_total_seam
case_end

case_begin "branch-run-exceeds-budget" "bin/lib/run-tests-baseline-branch.sh"
eb_branch_exceeds_after_run
case_end

case_begin "branch-rereads-ledger-next-call" "bin/lib/run-tests-baseline-branch.sh"
eb_branch_reread_next_call
case_end

case_begin "branch-budget-zero-exceeds-budget" "bin/lib/run-tests-baseline-branch.sh"
eb_branch_exceeds_budget_zero
case_end

case_begin "branch-timeout-only-stays-exhausted" "bin/lib/run-tests-baseline-branch.sh"
eb_branch_timeout_only
case_end

case_begin "branch-newest-timeout-stays-exhausted" "bin/lib/run-tests-baseline-branch.sh"
eb_branch_newest_timeout
case_end

case_begin "branch-unmeasured-stays-exhausted" "bin/lib/run-tests-baseline-branch.sh"
eb_branch_unmeasured
case_end

case_begin "branch-within-limit-stays-exhausted" "bin/lib/run-tests-baseline-branch.sh"
eb_branch_within_limit
case_end

case_begin "base-timeout-exceeds-budget" "bin/lib/run-tests-baseline-classify.sh"
eb_base_exceeds
case_end

case_begin "base-rereads-ledger-next-call" "bin/lib/run-tests-baseline-classify.sh"
eb_base_reread_next_call
case_end

case_begin "base-timeout-only-stays-exhausted" "bin/lib/run-tests-baseline-classify.sh"
eb_base_timeout_only
case_end

case_begin "base-newest-timeout-stays-exhausted" "bin/lib/run-tests-baseline-classify.sh"
eb_base_newest_timeout
case_end

case_begin "base-unmeasured-stays-exhausted" "bin/lib/run-tests-baseline-classify.sh"
eb_base_unmeasured
case_end

case_begin "base-within-limit-stays-exhausted" "bin/lib/run-tests-baseline-classify.sh"
eb_base_within_limit
case_end

eb_cli_setup
case_begin "cli-base-budget-zero-exceeds-budget" "bin/run-tests-baseline"
eb_cli_exceeds
case_end

case_begin "cli-base-budget-zero-stays-exhausted" "bin/run-tests-baseline"
eb_cli_budget_exhausted
case_end

case_begin "cli-branch-js-timeout-records-lang-cap" "bin/run-tests-baseline"
eb_cli_lang_cap
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
