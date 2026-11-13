#!/usr/bin/env bash
# tests/bin/feature-2956-baseline-branch-kill-skip.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-branch.sh
# Tags: run-tests, baseline, branch-rerun, scope:issue-specific, pwsh-not-required, TL2
# #2956 S8 table 2 - a branch copy killed (137 / 143) is undetermined ambiguous-exit (auto); a skipped
# branch copy (rc 77) has no records and goes to table 1: base records make it new-case-failure-on-branch
# case-records-missing-on-branch (pending), no records on either side file-verdict-preexisting
# no-case-records (auto). Interrupted / fails-alone rows: feature-2956-baseline-branch-paths.sh.
# TL3 gap: a kill sent by the OS (OOM) rather than the test's own exit is out of scope.

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

R="$TMPROOT/ks"; MK="$R.marks"
lp_rows_run "$R" 'k137|a|1|a|137
k143|a|1|a|143
skip|a|1||77
skip0||1||77'

case_begin "branch-kill-is-ambiguous-exit" "bin/lib/run-tests-baseline-branch.sh"
for c in 137 143; do
  present "k$c: the branch copy ran" "$MK/branch-k$c"
  has_line "k$c: ambiguous-exit-$c" "BASELINE: undetermined tests/bin/k$c.sh ambiguous-exit-$c"
  lacks_line "k$c: not preexisting" "BASELINE: preexisting tests/bin/k$c.sh"
done
case_end

case_begin "branch-skip-with-base-records-is-pending" "bin/run-tests-baseline"
present "skip: the base ran" "$MK/base-skip"
has_line "skip: base records, none on the branch" "BASELINE: new-case-failure-on-branch tests/bin/skip.sh case-records-missing-on-branch"
ck "ks: exit 1 (one pending row)" 1 "$RTB_RC"
case_end

case_begin "branch-skip-without-records-is-file-verdict" "bin/run-tests-baseline"
has_line "skip0: no records on either side" "BASELINE: file-verdict-preexisting tests/bin/skip0.sh no-case-records"
has_line "ks: summary counts" "file_verdict=1 new_on_branch=1"
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
