#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-corpus-without-base-result.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-decide-shadow.js, bin/lib/run-tests-baseline-decide.js
# Tags: run-tests, baseline, decide-shadow, corpus, branch-rerun, scope:common, pwsh-not-required, TL2, test-lang-exception:e2e
# decide corpus (1) part 1: the combinations decided without a base result. Every test is decided by the branch side solo re-run,
# and the merge base is not resolved (B2 of the RUN line is -). Passing alone (recorded exit 124 / 1 / 3 / none) and setup failure
# are outside-decide readings, so outside-decide; kill (137 / 143 with and without state) is compared with decide and is match.
# Checks the BASELINE lines (the oracle) of one real CLI run and the comparison outcome of each path in the divergence log.
# TL3 gap: does not wait for the real +10 s outer watchdog (the stub returns at once). The parser unit test owns that reading.

set -uo pipefail

export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-corpus-wob-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-corpus-wob-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/bin-run-tests-baseline-decide-corpus/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/bin-run-tests-baseline-decide-corpus/_lib.sh"

BA='state:FAIL rc:1'
cps_table <<TABLE
w-flaky.sh|n|124|$BA|state:PASS rc:0|flaky-timeout-on-branch exit-124-then-pass|no:outside-decide
w-pass1.sh|n|1|$BA|state:PASS rc:0|passes-alone-on-branch exit-1-then-pass|no:outside-decide
w-rc0.sh|n|3|$BA|rc:0|passes-alone-on-branch exit-3-then-pass|no:outside-decide
w-noexit.sh|n|-|$BA|state:PASS rc:0|passes-alone-on-branch exit-unknown-then-pass|no:outside-decide
w-setup.sh|n|1|$BA|launched:0 rc:2|undetermined exec-setup-failed|no:outside-decide
w-kill137.sh|n|1|$BA|state:FAIL rc:137|undetermined ambiguous-exit-137|match
w-kill143.sh|n|1|$BA|state:FAIL rc:143|undetermined ambiguous-exit-143|match
w-rc137.sh|n|1|$BA|rc:137|undetermined ambiguous-exit-137|match
w-rc143.sh|n|1|$BA|rc:143|undetermined ambiguous-exit-143|match
TABLE
cps_counts

case_begin "without-base-live-oracle" "bin/run-tests-baseline"
cps_build "$TMPROOT/repo" || fail "fixture: cannot build the repo"
cps_run "$TMPROOT/repo" "corpus-wob-$$"
cps_assert_live
cps_assert_writes
case_end

case_begin "without-base-divergence-log" "bin/lib/run-tests-baseline-decide-shadow.js"
adl_check "without-base" "$CPS_OUT" "$RUN_ALL_CACHE_DIR" "compared=$CPS_WANT_C" "no_comparison=$CPS_WANT_N"
if [ -n "$ADL_LOG" ] && sed -n '2p' "$ADL_LOG" | grep -q $'\t-$'; then pass "without-base: B2 of the RUN line is - (merge base not resolved)"
else fail "without-base: B2 of the RUN line is not -:$(sed -n '2p' "${ADL_LOG:-/dev/null}")"; fi
case_end

case_begin "without-base-per-path" "bin/lib/run-tests-baseline-decide.js"
cps_assert_shadow "without-base"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
