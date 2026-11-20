#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-corpus-base-result-state.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-decide-shadow.js, bin/lib/run-tests-baseline-decide.js
# Tags: run-tests, baseline, decide-shadow, corpus, base-result, scope:common, pwsh-not-required, TL2, test-lang-exception:e2e
# decide corpus (1) "merge base side readings": the combinations where the merge base side launcher reports a state.
# The branch side is the same line in every row, fails-alone. Varies the merge base side state and rc (PASS / FAIL with 1, 124, 142, 137, 143 / SKIP).
# Checks the BASELINE lines (the oracle) of one real CLI run and the comparison outcome of each path in the divergence log.
# For time, the merge base side readings are split into -base-result-markers.sh / -base-result-state.sh / -base-result-rc.sh.
# TL3 gap: does not wait for the real +10 s outer watchdog (the stub returns at once). The parser unit test owns that reading.

set -uo pipefail

export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-corpus-bstate-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-corpus-bstate-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/bin-run-tests-baseline-decide-corpus/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/bin-run-tests-baseline-decide-corpus/_lib.sh"

BR='state:FAIL rc:1 case:FAIL:case-a:line-X'
cps_table <<TABLE
s-pass.sh|n|1|state:PASS rc:0 case:PASS:case-a|$BR|broken passes-at-base|match
s-same.sh|n|1|state:FAIL rc:1 case:FAIL:case-a:line-X|$BR|preexisting fails-at-base-exit-1|match
s-skip.sh|n|1|state:SKIP rc:77|$BR|undetermined skip-at-base|match
s-fail124.sh|n|1|state:FAIL rc:124 case:FAIL:case-a:line-X|$BR|preexisting fails-at-base-exit-124|match
s-fail142.sh|n|1|state:FAIL rc:142 case:FAIL:case-a:line-X|$BR|preexisting fails-at-base-exit-142|match
s-fail137.sh|n|1|state:FAIL rc:137|$BR|undetermined ambiguous-exit-137|match
s-fail143.sh|n|1|state:FAIL rc:143|$BR|undetermined ambiguous-exit-143|match
TABLE
cps_counts

case_begin "base-state-live-oracle" "bin/run-tests-baseline"
cps_build "$TMPROOT/repo" || fail "fixture: cannot build the repo"
cps_run "$TMPROOT/repo" "corpus-bstate-$$"
cps_assert_live
cps_assert_writes
case_end

case_begin "base-state-divergence-log" "bin/lib/run-tests-baseline-decide-shadow.js"
adl_check "base-state" "$CPS_OUT" "$RUN_ALL_CACHE_DIR" "compared=$CPS_WANT_C" "no_comparison=$CPS_WANT_N"
case_end

case_begin "base-state-per-path" "bin/lib/run-tests-baseline-decide.js"
cps_assert_shadow "base-state"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
