#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-corpus-branch-unrunnable-timeout.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-decide-shadow.js, bin/lib/run-tests-baseline-decide.js
# Tags: run-tests, baseline, decide-shadow, corpus, branch-result, scope:common, pwsh-not-required, TL2, test-lang-exception:e2e
# decide corpus (1) "branch result against the merge base side": the branch side is unrunnable, or a recordable timeout
# (no --per-test-timeout is passed, so the default 300 s gives timeout-after-300s). The merge base side is pass / same lines / timeout.
# Checks the BASELINE lines (the oracle) of one real CLI run and the comparison outcome of each path in the divergence log.
# TL3 gap: does not wait for the real +10 s outer watchdog (the stub returns at once). The parser unit test owns that reading.

set -uo pipefail

export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-corpus-but-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-corpus-but-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/bin-run-tests-baseline-decide-corpus/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/bin-run-tests-baseline-decide-corpus/_lib.sh"

P='state:PASS rc:0 case:PASS:case-a' S='state:FAIL rc:1 case:FAIL:case-a:line-X' T='state:TIMEOUT rc:124'
UR='state:UNRUNNABLE rc:1 missing:pwsh'
cps_table <<TABLE
ur-pass.sh|n|1|$P|$UR|new-case-failure-on-branch case-records-missing-on-branch|match
ur-same.sh|n|1|$S|$UR|new-case-failure-on-branch case-records-missing-on-branch|match
ur-timeout.sh|n|1|$T|$UR|undetermined timeout-at-base|match
to-pass.sh|n|1|$P|$T|broken passes-at-base|match
to-same.sh|n|1|$S|$T|new-case-failure-on-branch case-records-missing-on-branch|match
to-timeout.sh|n|1|$T|$T|undetermined timeout-at-base|match
TABLE
cps_counts

case_begin "branch-unrunnable-timeout-live-oracle" "bin/run-tests-baseline"
cps_build "$TMPROOT/repo" || fail "fixture: cannot build the repo"
cps_run "$TMPROOT/repo" "corpus-but-$$"
cps_assert_live
cps_assert_writes
case_end

case_begin "branch-unrunnable-timeout-divergence-log" "bin/lib/run-tests-baseline-decide-shadow.js"
adl_check "branch-unrunnable-timeout" "$CPS_OUT" "$RUN_ALL_CACHE_DIR" "compared=$CPS_WANT_C" "no_comparison=$CPS_WANT_N"
case_end

case_begin "branch-unrunnable-timeout-per-path" "bin/lib/run-tests-baseline-decide.js"
cps_assert_shadow "branch-unrunnable-timeout"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
