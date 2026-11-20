#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-corpus-branch-interrupted.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-decide-shadow.js, bin/lib/run-tests-baseline-decide.js
# Tags: run-tests, baseline, decide-shadow, corpus, branch-result, scope:common, pwsh-not-required, TL2, test-lang-exception:e2e
# decide corpus (1) "branch result against the merge base side": the combinations where the branch side left records and was cut off
# (FAIL 124 / 142, rc 124 / 142 with no state), and fails-alone against a merge base side timeout. The merge base side is pass / same lines / different lines / timeout.
# Checks the BASELINE lines (the oracle) of one real CLI run and the comparison outcome of each path in the divergence log.
# The branch result combinations are split into -branch-interrupted / -branch-guard-decoy / -branch-no-records / -branch-unrunnable-timeout.
# TL3 gap: does not wait for the real +10 s outer watchdog (the stub returns at once). The parser unit test owns that reading.

set -uo pipefail

export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-corpus-bint-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-corpus-bint-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/bin-run-tests-baseline-decide-corpus/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/bin-run-tests-baseline-decide-corpus/_lib.sh"

P='state:PASS rc:0 case:PASS:case-a' S='state:FAIL rc:1 case:FAIL:case-a:line-X'
N='state:FAIL rc:1 case:FAIL:case-a:line-Y' T='state:TIMEOUT rc:124'
cps_table <<TABLE
i124-pass.sh|n|1|$P|state:FAIL rc:124 case:FAIL:case-a:line-X|broken passes-at-base|match
i124-same.sh|n|1|$S|state:FAIL rc:124 case:FAIL:case-a:line-X|preexisting fails-at-base-exit-1|match
i124-new.sh|n|1|$N|state:FAIL rc:124 case:FAIL:case-a:line-X|new-case-failure-on-branch fails-at-base-exit-1-new-lines new=1 head=["case-a\tline-X"]|match
i124-timeout.sh|n|1|$T|state:FAIL rc:124 case:FAIL:case-a:line-X|undetermined timeout-at-base|match
i142-same.sh|n|1|$S|state:FAIL rc:142 case:FAIL:case-a:line-X|preexisting fails-at-base-exit-1|match
fa-timeout.sh|n|1|$T|$S|undetermined timeout-at-base|match
n124-new.sh|n|1|$N|rc:124 case:FAIL:case-a:line-X|new-case-failure-on-branch fails-at-base-exit-1-new-lines new=1 head=["case-a\tline-X"]|match
n142-same.sh|n|1|$S|rc:142 case:FAIL:case-a:line-X|preexisting fails-at-base-exit-1|match
TABLE
# spec-pending: branch side ?/? reading — n124 / n142 expect match, following live, which reads an rc with no state as interrupted.
cps_counts

case_begin "branch-interrupted-live-oracle" "bin/run-tests-baseline"
cps_build "$TMPROOT/repo" || fail "fixture: cannot build the repo"
cps_run "$TMPROOT/repo" "corpus-bint-$$"
cps_assert_live
cps_assert_writes
case_end

case_begin "branch-interrupted-divergence-log" "bin/lib/run-tests-baseline-decide-shadow.js"
adl_check "branch-interrupted" "$CPS_OUT" "$RUN_ALL_CACHE_DIR" "compared=$CPS_WANT_C" "no_comparison=$CPS_WANT_N"
case_end

case_begin "branch-interrupted-per-path" "bin/lib/run-tests-baseline-decide.js"
cps_assert_shadow "branch-interrupted"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
