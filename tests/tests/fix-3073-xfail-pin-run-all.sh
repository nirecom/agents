#!/usr/bin/env bash
# fix-3073-xfail-pin-run-all.sh — an xfail pin keeps a known gap out of run-all's failures (#3073).
# Tests: tests/run-all.sh, bin/lib/run-all-classify.sh, bin/lib/run-all-report.sh, tests/lib/xfail.sh
# Tags: tests, run-all, xfail, report, exit-code, scope:issue-specific

# WHY: #3073 pins the known gaps of the main-branch suite with xfail_* instead of leaving them red.
# That only works if run-all counts an unmet pin as no failure (T-X1), still fails a met pin, so a
# stale pin is noticed (T-X2), and still fails an unpinned assertion (T-X3). T-X2 and T-X3 are the
# controls proving T-X1's fixture really ran its assertion.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/feature-2501-run-all-report/_fx.sh"
# shellcheck source=../lib/harness.sh
. "$FX_REPO_ROOT/tests/lib/harness.sh"

fx_init "fix-3073-xfail-pin-run-all"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export WORKFLOW_STATE_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID RUN_ALL_TIMEOUT_SECONDS 2>/dev/null || true

R="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }

# The fixture's own marker words are split so this file's marker scan does not read them as ours.
X_BEGIN="case_""begin" X_END="case_""end"

# x_fixture <id> <assertion line> [<last line>] — a harness test with one case holding one
# assertion; the last line (default: exit non-zero on any failure) decides the file's rc.
x_fixture() {
    rr_add_raw "$R" "$1" \
        "$(printf '. %q/tests/lib/harness.sh' "$FX_REPO_ROOT")" \
        "XFAIL_ISSUE='#3073'" \
        "$(printf '. %q/tests/lib/xfail.sh' "$FX_REPO_ROOT")" \
        "$X_BEGIN \"pinned-gap\" \"tests/lib/xfail.sh\"" \
        "$2" \
        "$X_END" \
        'xfail_summary' \
        "${3:-[ \"\$FAIL\" -eq 0 ]}"
}
x_fixture x1-unmet-pin 'xfail_eq "gap still open" "correct" "buggy"'
x_fixture x2-met-pin 'xfail_eq "gap closed" "correct" "correct"'
x_fixture x3-unpinned 'assert_eq "buggy" "correct"'
# A file that exits 0 despite its XPASS: only run-all's own XPASS count can fail it.
x_fixture x4-met-pin-rc0 'xfail_eq "gap closed" "correct" "correct"' 'exit 0'

# x_run <id> — run-all on that one fixture file; rc in X_RC, output at $FX_TMP_ROOT/<id>.out.
x_run() {
    X_RC=0
    rr_exec "$R" 120 "$FX_TMP_ROOT/$1.out" "$FX_TMP_ROOT/$1.err" -j 1 "$R/tests/bin/$1.sh" || X_RC=$?
    X_OUT="$FX_TMP_ROOT/$1.out"
}
# x_has <ERE> — 0 when the last run's stdout has a matching line.
x_has() { grep -qE -- "$1" "$X_OUT" 2>/dev/null; }
x_diag() { fx_show_tail "$X_OUT" 15; }

case_begin "unmet-pin-is-not-a-failure" "bin/lib/run-all-classify.sh"
x_run x1-unmet-pin
fx_check "$X_RC" "T-X1. an xfail-only failing file: run-all exits 0 (rc=$X_RC)"
if x_has '^[[:blank:]]*FAIL:'; then fx_fail "T-X1. no FAIL: line for the unmet pin"; x_diag
else fx_pass "T-X1. no FAIL: line for the unmet pin"; fi
x_has '^XFAIL .*x1-unmet-pin\.sh::pinned-gap'
fx_check $? "T-X1. the pinned case is reported as an XFAIL line"
x_has '^RUN_CONTRACT: PASS=1 FAIL=0 '
fx_check $? "T-X1. the contract counts the file as a pass, not a failure"
case_end

case_begin "met-pin-is-a-failure" "bin/lib/run-all-classify.sh"
x_run x2-met-pin
if [ "$X_RC" -ne 0 ]; then fx_pass "T-X2. a met pin (XPASS): run-all exits non-zero (rc=$X_RC)"
else fx_fail "T-X2. a met pin (XPASS): run-all exits non-zero (rc=0)"; x_diag; fi
x_has '^[[:blank:]]*FAIL:.*x2-met-pin\.sh'
fx_check $? "T-X2. the file appears on a FAIL: line"
x_has '^XPASS .*x2-met-pin\.sh::pinned-gap'
fx_check $? "T-X2. the pinned case is reported as an XPASS line"
x_run x4-met-pin-rc0
if [ "$X_RC" -ne 0 ]; then fx_pass "T-X2b. a met pin in a file that exits 0: run-all still exits non-zero (rc=$X_RC)"
else fx_fail "T-X2b. a met pin in a file that exits 0: run-all still exits non-zero (rc=0)"; x_diag; fi
x_has '^[[:blank:]]*FAIL:.*x4-met-pin-rc0\.sh'
fx_check $? "T-X2b. the rc-0 file still appears on a FAIL: line"
case_end

case_begin "unpinned-failure-is-a-failure" "tests/run-all.sh"
x_run x3-unpinned
if [ "$X_RC" -ne 0 ]; then fx_pass "T-X3. an unpinned failing assertion: run-all exits non-zero (rc=$X_RC)"
else fx_fail "T-X3. an unpinned failing assertion: run-all exits non-zero (rc=0)"; x_diag; fi
x_has '^[[:blank:]]*FAIL:.*x3-unpinned\.sh'
fx_check $? "T-X3. the file appears on a FAIL: line"
case_end

fx_finish
