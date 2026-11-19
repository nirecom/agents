#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-corpus-base-result-rc.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-decide-shadow.js, bin/lib/run-tests-baseline-decide.js
# Tags: run-tests, baseline, decide-shadow, corpus, base-result, scope:common, pwsh-not-required, TL2, test-lang-exception:e2e
# decide corpus (1) "merge base side readings": the rc reading of a bash test whose merge base side launcher reports no state
# (0 / 1 / 77 / 124 / 137 / 142 / 143). The branch side is the same line in every row, fails-alone.
# Recorded discrepancy 2 (124 / 137 / 142 / 143 with no state) is intended, so it counts as match.
# Checks the BASELINE lines (the oracle) of one real CLI run and the comparison outcome of each path in the divergence log.
# TL3 gap: does not wait for the real +10 s outer watchdog (the stub returns at once). The parser unit test owns that reading.

set -uo pipefail

export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-corpus-brc-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-corpus-brc-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/bin-run-tests-baseline-decide-corpus/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/bin-run-tests-baseline-decide-corpus/_lib.sh"

BR='state:FAIL rc:1 case:FAIL:case-a:line-X'
cps_table <<TABLE
r-rc0.sh|n|1|rc:0|$BR|broken passes-at-base|match
r-rc1.sh|n|1|rc:1 case:FAIL:case-a:line-X|$BR|preexisting fails-at-base-exit-1|match
r-rc77.sh|n|1|rc:77|$BR|undetermined skip-at-base|match
r-rc124.sh|n|1|rc:124|$BR|undetermined ambiguous-exit-124|match
r-rc137.sh|n|1|rc:137|$BR|undetermined ambiguous-exit-137|match
r-rc142.sh|n|1|rc:142|$BR|undetermined ambiguous-exit-142|match
r-rc143.sh|n|1|rc:143|$BR|undetermined ambiguous-exit-143|match
TABLE
cps_counts

case_begin "base-rc-live-oracle" "bin/run-tests-baseline"
cps_build "$TMPROOT/repo" || fail "fixture: cannot build the repo"
cps_run "$TMPROOT/repo" "corpus-brc-$$"
cps_assert_live
cps_assert_writes
case_end

case_begin "base-rc-divergence-log" "bin/lib/run-tests-baseline-decide-shadow.js"
adl_check "base-rc" "$CPS_OUT" "$RUN_ALL_CACHE_DIR" "compared=$CPS_WANT_C" "no_comparison=$CPS_WANT_N"
case_end

case_begin "base-rc-per-path" "bin/lib/run-tests-baseline-decide.js"
cps_assert_shadow "base-rc"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
