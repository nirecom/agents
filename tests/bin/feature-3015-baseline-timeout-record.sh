#!/usr/bin/env bash
# tests/bin/feature-3015-baseline-timeout-record.sh
# Tests: bin/lib/run-tests-baseline-branch.sh, bin/lib/run-tests-baseline-classify.sh, bin/lib/run-tests-baseline-timeout.sh, bin/lib/run-tests-baseline-rename.sh
# Tags: run-tests, baseline, timeout, ledger, cache, rename, scope:issue-specific, pwsh-not-required, TL2
# #3015: a test that timed out at its full requested timeout is recorded (branch cache
# `timeout-after-<N>s`, ledger `und:timeout-at-base-after-<N>s`) and reused when N >= requested, so
# repeated baseline runs converge. Lib-level cases with a stubbed test run (every run times out).
# TL3 gap: a real test that sleeps past 300s is not run; the stub stands in for the launcher's timeout.
# Case bodies: feature-3015-baseline-timeout-record/{unit,branch,base}.sh; setup: _lib.sh, driver.sh.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
TR_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-3015-baseline-timeout-record"
# shellcheck source=./feature-3015-baseline-timeout-record/_lib.sh
. "$TR_DIR/_lib.sh"
# shellcheck source=./feature-3015-baseline-timeout-record/unit.sh
. "$TR_DIR/unit.sh"
# shellcheck source=./feature-3015-baseline-timeout-record/branch.sh
. "$TR_DIR/branch.sh"
# shellcheck source=./feature-3015-baseline-timeout-record/base.sh
. "$TR_DIR/base.sh"

TR_REPO="$TMPROOT/repo"
tr_repo "$TR_REPO"
tr_unit_probe

case_begin "timeout-requested-and-its-source" "bin/lib/run-tests-baseline-timeout.sh"
tr_unit_requested
case_end

case_begin "timeout-recordable-predicate" "bin/lib/run-tests-baseline-timeout.sh"
tr_unit_recordable
case_end

case_begin "timeout-unrecordable-note-wording" "bin/lib/run-tests-baseline-timeout.sh"
tr_unit_note
case_end

case_begin "rename-base-path-of-a-test" "bin/lib/run-tests-baseline-rename.sh"
tr_unit_base_path
case_end

case_begin "branch-timeout-at-requested-is-recorded" "bin/lib/run-tests-baseline-branch.sh"
tr_branch_recorded
case_end

case_begin "branch-timeout-cache-hit-skips-rerun" "bin/lib/run-tests-baseline-branch.sh"
tr_branch_hit
case_end

case_begin "branch-timeout-hit-needs-n-at-least-requested" "bin/lib/run-tests-baseline-branch.sh"
tr_branch_boundary
case_end

case_begin "branch-timeout-row-hits-only-when-well-formed" "bin/lib/run-tests-baseline-branch.sh"
tr_branch_cache_row
case_end

case_begin "branch-timeout-shortened-by-budget-is-not-recorded" "bin/lib/run-tests-baseline-branch.sh"
tr_branch_budget_cut
case_end

case_begin "branch-timeout-above-the-stage-cap-is-noted" "bin/lib/run-tests-baseline-branch.sh"
tr_branch_cap
case_end

case_begin "branch-explicit-below-derived-is-noted" "bin/lib/run-tests-baseline-branch.sh"
tr_branch_explicit_low
case_end

case_begin "branch-explicit-at-or-above-derived-is-recorded" "bin/lib/run-tests-baseline-branch.sh"
tr_branch_explicit_high
case_end

case_begin "base-timeout-recorded-only-when-full-length" "bin/lib/run-tests-baseline-classify.sh"
tr_base_timeout
case_end

case_begin "base-timeout-round-trip-hits-same-base-misses-other" "bin/lib/run-tests-baseline-classify.sh"
tr_base_timeout_round_trip
case_end

case_begin "ledger-stage-reuses-base-timeout-at-or-above-requested" "bin/lib/run-tests-baseline-classify.sh"
tr_ledger_hit
case_end

case_begin "ledger-malformed-timeout-rows-are-misses" "bin/lib/run-tests-baseline-classify.sh"
tr_ledger_malformed
case_end

case_begin "ledger-stage-newest-row-wins-over-a-timeout" "bin/lib/run-tests-baseline-classify.sh"
tr_ledger_newest
case_end

case_begin "ledger-stage-never-inherits-a-timeout-row" "bin/lib/run-tests-baseline-classify.sh"
tr_ledger_no_inherit
case_end

case_begin "ledger-stage-looks-up-the-rename-source" "bin/lib/run-tests-baseline-classify.sh"
tr_ledger_rename
case_end

case_begin "branch-timeout-means-no-branch-records" "bin/lib/run-tests-baseline-classify.sh"
tr_no_branch_records
case_end

case_begin "branch-timeout-skips-inheritance" "bin/lib/run-tests-baseline-classify.sh"
tr_no_inherit_on_branch_timeout
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
