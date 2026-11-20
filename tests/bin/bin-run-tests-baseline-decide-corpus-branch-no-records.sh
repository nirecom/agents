#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-corpus-branch-no-records.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-decide-shadow.js, bin/lib/run-tests-baseline-decide.js
# Tags: run-tests, baseline, decide-shadow, corpus, branch-result, scope:common, pwsh-not-required, TL2, test-lang-exception:e2e
# decide corpus (1) "branch result against the merge base side": branch results that leave no failing lines:
# state SKIP, rc 77 with no state, an unknown state (WEIRD), unsupported (not launched). The merge base side is pass / same lines.
# Checks the BASELINE lines (the oracle) of one real CLI run and the comparison outcome of each path in the divergence log.
# TL3 gap: does not wait for the real +10 s outer watchdog (the stub returns at once). The parser unit test owns that reading.

set -uo pipefail

export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-corpus-bnr-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-corpus-bnr-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/bin-run-tests-baseline-decide-corpus/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/bin-run-tests-baseline-decide-corpus/_lib.sh"

P='state:PASS rc:0 case:PASS:case-a' S='state:FAIL rc:1 case:FAIL:case-a:line-X'
cps_table <<TABLE
sk-pass.sh|n|1|$P|state:SKIP rc:77|broken passes-at-base|match
sk-same.sh|n|1|$S|state:SKIP rc:77|new-case-failure-on-branch case-records-missing-on-branch|match
s77-pass.sh|n|1|$P|rc:77|broken passes-at-base|match
s77-same.sh|n|1|$S|rc:77|new-case-failure-on-branch case-records-missing-on-branch|match
us-pass.sh|n|1|$P|launched:0 rc:78|broken passes-at-base|match
us-same.sh|n|1|$S|launched:0 rc:78|new-case-failure-on-branch case-records-missing-on-branch|match
sw1-same.sh|n|1|$S|state:WEIRD rc:1 case:FAIL:case-a:line-X|new-case-failure-on-branch case-records-missing-on-branch|recorded:discrepancy-6
TABLE
# spec-pending: branch side ?/? reading — live reads an unknown state X as skip. decide reads ?/? rc 1 as a fail with no state,
# so sw1 is expected to be the record of discrepancy 6 (recorded:discrepancy-6). The id spelling is a provisional value set in write_code.
cps_counts

case_begin "branch-no-records-live-oracle" "bin/run-tests-baseline"
cps_build "$TMPROOT/repo" || fail "fixture: cannot build the repo"
cps_run "$TMPROOT/repo" "corpus-bnr-$$"
cps_assert_live
cps_assert_writes
case_end

case_begin "branch-no-records-divergence-log" "bin/lib/run-tests-baseline-decide-shadow.js"
adl_check "branch-no-records" "$CPS_OUT" "$RUN_ALL_CACHE_DIR" "compared=$CPS_WANT_C" "no_comparison=$CPS_WANT_N"
case_end

case_begin "branch-no-records-per-path" "bin/lib/run-tests-baseline-decide.js"
cps_assert_shadow "branch-no-records"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
