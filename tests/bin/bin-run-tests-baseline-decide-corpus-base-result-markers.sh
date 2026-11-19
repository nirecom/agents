#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-corpus-base-result-markers.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-decide-shadow.js, bin/lib/run-tests-baseline-decide.js
# Tags: run-tests, baseline, decide-shadow, corpus, base-result, scope:common, pwsh-not-required, TL2, test-lang-exception:e2e
# decide corpus (1) "merge base side readings": the markers read before state / rc, and the outside-decide readings.
# The branch side is the same line in every row, fails-alone. The merge base side is timeout / unsupported / decoy / guard only / unrunnable /
# setup failure / unknown state / wrapper language with no state. Recorded discrepancy 3 (guard only) is recorded:<id>.
# Checks the BASELINE lines (the oracle) of one real CLI run and the comparison outcome of each path in the divergence log.
# TL3 gap: does not wait for the real +10 s outer watchdog (the stub returns at once). The parser unit test owns that reading.

set -uo pipefail

export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-corpus-bmark-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-corpus-bmark-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/bin-run-tests-baseline-decide-corpus/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/bin-run-tests-baseline-decide-corpus/_lib.sh"

BR='state:FAIL rc:1 case:FAIL:case-a:line-X'
cps_table <<TABLE
m-timeout.sh|n|1|state:TIMEOUT rc:124|$BR|undetermined timeout-at-base|match
m-unsupported.sh|n|1|launched:0 rc:78|$BR|undetermined unsupported-at-base|match
m-decoy.sh|n|1|state:FAIL rc:1 hits:1 err:decoy case:FAIL:case-a:line-X|$BR|undetermined root-decoy-hit-at-base|match
m-guard.sh|n|1|state:FAIL rc:1 hits:1 err:guard case:FAIL:case-a:line-X|$BR|undetermined root-decoy-hit-at-base|recorded:discrepancy-3
m-unrunnable.sh|n|1|state:UNRUNNABLE rc:1 missing:pwsh|$BR|undetermined unrunnable-at-base|match
m-setup.sh|n|1|launched:0 rc:2|$BR|undetermined exec-setup-failed|no:outside-decide
m-weird.sh|n|1|state:WEIRD rc:1|$BR|undetermined state-WEIRD-at-base|no:outside-decide
m-wrapper.js|n|1|rc:1|$BR|undetermined base-launcher-predates-result-conversion|no:outside-decide
TABLE
cps_counts

case_begin "base-markers-live-oracle" "bin/run-tests-baseline"
cps_build "$TMPROOT/repo" || fail "fixture: cannot build the repo"
cps_run "$TMPROOT/repo" "corpus-bmark-$$"
cps_assert_live
cps_assert_writes
case_end

case_begin "base-markers-divergence-log" "bin/lib/run-tests-baseline-decide-shadow.js"
adl_check "base-markers" "$CPS_OUT" "$RUN_ALL_CACHE_DIR" "compared=$CPS_WANT_C" "no_comparison=$CPS_WANT_N"
case_end

case_begin "base-markers-per-path" "bin/lib/run-tests-baseline-decide.js"
cps_assert_shadow "base-markers"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
