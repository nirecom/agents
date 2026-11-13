#!/usr/bin/env bash
# tests/bin/feature-2956-baseline-branch-paths.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-branch.sh
# Tags: run-tests, baseline, branch-rerun, scope:issue-specific, pwsh-not-required, TL2
# #2956 S4 step 4 / S8 table 2 - an interrupted branch run (rc 124 / 142) missing a base FAIL case is
# pending (never a proof); with every base case it is compared as usual; a finished fails-alone run
# missing one counts it as fixed and stays preexisting. Kill and skip rows:
# feature-2956-baseline-branch-kill-skip.sh. Other table 2 rows: feature-2688-branch-{cache,rerun}.sh
# (not-run, outer timeout, decoy, unrunnable) and feature-2431-run-tests-baseline/cli-unsupported.sh.
# TL3 gap: a real harness stopped mid-case by its own alarm is out of scope.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2688-branch-rerun/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2688-branch-rerun/_lib.sh"
# shellcheck source=tests/bin/feature-2956-baseline-ledger-paths/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2956-baseline-ledger-paths/_lib.sh"

R="$TMPROOT/t2"; MK="$R.marks"
lp_rows_run "$R" 'i124|a b|1|a|124
i124all|a b|1|a b|124
i142|a b|1|a|142
alone|a b|1|a|1'

case_begin "interrupted-run-missing-a-base-case-is-pending" "bin/run-tests-baseline"
ck "t2: exit 1 (pending rows present)" 1 "$RTB_RC"
for s in i124 i142; do
  present "$s: the branch copy ran" "$MK/branch-$s"
  has_line "$s: partial records are not a proof" "BASELINE: new-case-failure-on-branch tests/bin/$s.sh case-records-missing-on-branch"
  lacks_line "$s: not preexisting" "BASELINE: preexisting tests/bin/$s.sh"
done
case_end

case_begin "interrupted-run-with-every-base-case-is-compared" "bin/run-tests-baseline"
has_line "i124all: same lines - preexisting" "BASELINE: preexisting tests/bin/i124all.sh"
case_end

case_begin "fails-alone-missing-a-base-case-stays-preexisting" "bin/lib/run-tests-baseline-branch.sh"
present "alone: the branch copy ran" "$MK/branch-alone"
has_line "alone: a finished run counts the absent case as fixed" "BASELINE: preexisting tests/bin/alone.sh"
has_line "t2: summary counts" "file_verdict=0 new_on_branch=2"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
