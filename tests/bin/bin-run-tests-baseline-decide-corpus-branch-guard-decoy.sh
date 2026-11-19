#!/usr/bin/env bash
# tests/bin/bin-run-tests-baseline-decide-corpus-branch-guard-decoy.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-decide-shadow.js, bin/lib/run-tests-baseline-decide.js
# Tags: run-tests, baseline, decide-shadow, corpus, branch-result, scope:common, pwsh-not-required, TL2, test-lang-exception:e2e
# decide corpus (1) "branch result against the merge base side": hits on the branch side. A guard-only FAIL
# leaves records as that test's FAIL; a root decoy hit leaves no records (a changed test's decoy is in -case-changed.sh).
# The merge base side is pass / same lines / different lines / timeout.
# Checks the BASELINE lines (the oracle) of one real CLI run and the comparison outcome of each path in the divergence log.
# TL3 gap: does not wait for the real +10 s outer watchdog (the stub returns at once). The parser unit test owns that reading.

set -uo pipefail

export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/rtb-corpus-bgd-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/rtb-corpus-bgd-plans-$$"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/bin-run-tests-baseline-decide-corpus/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/bin-run-tests-baseline-decide-corpus/_lib.sh"

P='state:PASS rc:0 case:PASS:case-a' S='state:FAIL rc:1 case:FAIL:case-a:line-X'
N='state:FAIL rc:1 case:FAIL:case-a:line-Y' T='state:TIMEOUT rc:124'
GD='state:FAIL rc:1 hits:1 err:guard case:FAIL:case-a:line-X' DC='state:FAIL rc:1 hits:1 err:decoy'
cps_table <<TABLE
gd-pass.sh|n|1|$P|$GD|broken passes-at-base|match
gd-same.sh|n|1|$S|$GD|preexisting fails-at-base-exit-1|match
gd-new.sh|n|1|$N|$GD|new-case-failure-on-branch fails-at-base-exit-1-new-lines new=1 head=["case-a\tline-X"]|match
gd-timeout.sh|n|1|$T|$GD|undetermined timeout-at-base|match
dc-pass.sh|n|1|$P|$DC|new-case-failure-on-branch case-records-missing-on-branch|match
dc-same.sh|n|1|$S|$DC|undetermined root-decoy-hit-on-branch|match
TABLE
cps_counts

case_begin "branch-guard-decoy-live-oracle" "bin/run-tests-baseline"
cps_build "$TMPROOT/repo" || fail "fixture: cannot build the repo"
cps_run "$TMPROOT/repo" "corpus-bgd-$$"
cps_assert_live
cps_assert_writes
case_end

case_begin "branch-guard-decoy-divergence-log" "bin/lib/run-tests-baseline-decide-shadow.js"
adl_check "branch-guard-decoy" "$CPS_OUT" "$RUN_ALL_CACHE_DIR" "compared=$CPS_WANT_C" "no_comparison=$CPS_WANT_N"
case_end

case_begin "branch-guard-decoy-per-path" "bin/lib/run-tests-baseline-decide.js"
cps_assert_shadow "branch-guard-decoy"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
