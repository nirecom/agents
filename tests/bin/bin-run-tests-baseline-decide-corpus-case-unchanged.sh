#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-corpus-case-unchanged.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-decide-shadow.js, bin/lib/run-tests-baseline-decide.js
# Tags: run-tests, baseline, decide-shadow, corpus, case-compare, scope:common, pwsh-not-required, TL2, test-lang-exception:e2e
# decide corpus (1) "case comparison": the combinations where the test file did not change on the branch.
# Both the branch side and the merge base side FAIL, with failing lines same / new / none on either / none on the branch side only / none on the merge base side only.
# Checks the BASELINE lines (the oracle) of one real CLI run and the comparison outcome of each path in the divergence log.
# The same combinations for a changed test are in -case-changed.sh.
# TL3 gap: does not wait for the real +10 s outer watchdog (the stub returns at once). The parser unit test owns that reading.

set -uo pipefail

export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-corpus-cun-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-corpus-cun-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/bin-run-tests-baseline-decide-corpus/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/bin-run-tests-baseline-decide-corpus/_lib.sh"

X='state:FAIL rc:1 case:FAIL:case-a:line-X' Y='state:FAIL rc:1 case:FAIL:case-a:line-Y' Z='state:FAIL rc:1'
cps_table <<TABLE
cu-same.sh|n|1|$X|$X|preexisting fails-at-base-exit-1|match
cu-new.sh|n|1|$X|$Y|new-case-failure-on-branch fails-at-base-exit-1-new-lines new=1 head=["case-a\tline-Y"]|match
cu-norec.sh|n|1|$Z|$Z|file-verdict-preexisting no-case-records|match
cu-brmiss.sh|n|1|$X|$Z|new-case-failure-on-branch case-records-missing-on-branch|match
cu-basemiss.sh|n|1|$Z|$X|new-case-failure-on-branch case-records-missing-at-base new=1 head=["case-a\tline-X"]|match
TABLE
cps_counts

case_begin "case-unchanged-live-oracle" "bin/run-tests-baseline"
cps_build "$TMPROOT/repo" || fail "fixture: cannot build the repo"
cps_run "$TMPROOT/repo" "corpus-cun-$$"
cps_assert_live
cps_assert_writes
case_end

case_begin "case-unchanged-divergence-log" "bin/lib/run-tests-baseline-decide-shadow.js"
adl_check "case-unchanged" "$CPS_OUT" "$RUN_ALL_CACHE_DIR" "compared=$CPS_WANT_C" "no_comparison=$CPS_WANT_N"
case_end

case_begin "case-unchanged-per-path" "bin/lib/run-tests-baseline-decide.js"
cps_assert_shadow "case-unchanged"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
