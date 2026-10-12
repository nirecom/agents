#!/usr/bin/env bash
# a-unit-order-and-records.sh — per-unit report block and case-record resolution (#2501).
# Tests: bin/lib/run-all-report.sh, tests/run-all.sh
# Tags: tests, bin, run-all, report, scope:issue-specific

# WHY: each unit's block is child stdout, then its file-level line, then its case lines
# (`<STATE> <file>::<case> target=<t>`), replayed in submission order so -j never changes
# stdout. Records the harness leaves OPEN / UNOBSERVED are resolved here, not by the test.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_fx.sh"
# shellcheck source=../../lib/harness.sh
. "$FX_REPO_ROOT/tests/lib/harness.sh"

fx_init "a-unit-order-and-records"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export WORKFLOW_STATE_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
rr_require_report

R="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
rr_add_harness "$R" u1-cases <<'FX'
echo "U1-CHILD-STDOUT"
case_begin "c1" "tests/run-all.sh"
pass "one"
case_end
case_begin "c2" "tests/lib/harness.sh"
pass "two"
case_end
exit 0
FX
fx_add_dummy "$R" u2-nocases --lines 1
rr_add_harness "$R" u3-fail-onlypass <<'FX'
case_begin "c1" "tests/run-all.sh"
pass "one"
case_end
exit 1
FX
rr_add_harness "$R" u4-open-fail <<'FX'
case_begin "c-open" "tests/run-all.sh"
pass "one"
exit 1
FX
rr_add_harness "$R" u5-open-pass <<'FX'
case_begin "c-done" "tests/run-all.sh"
pass "one"
case_end
case_begin "c-open" "tests/run-all.sh"
pass "two"
exit 0
FX
rr_add_harness "$R" u7-open-failed-exit0 <<'FX'
case_begin "c-bad" "tests/run-all.sh"
fail "one"
exit 0
FX
rr_add_harness "$R" u8-open-failed-exit77 <<'FX'
case_begin "c-bad" "tests/run-all.sh"
fail "one"
exit 77
FX
rr_add_harness "$R" u6-unobserved <<'FX'
case_begin "c-quiet" "tests/run-all.sh"
echo "no counter moves here"
case_end
exit 0
FX

O1="$FX_TMP_ROOT/j1.out"; O4="$FX_TMP_ROOT/j4.out"
rr_exec "$R" 90 "$O1" "$FX_TMP_ROOT/j1.err" -j 1 --all; RC1=$?
rr_exec "$R" 90 "$O4" "$FX_TMP_ROOT/j4.err" -j 4 --all; RC4=$?

case_begin "unit-block-order" "bin/lib/run-all-report.sh"
c_ln="$(rr_line_no "$O4" '^U1-CHILD-STDOUT$')"
f_ln="$(rr_line_no "$O4" '^PASS: .*u1-cases\.sh$')"
k1="$(rr_line_no "$O4" '^PASS .*u1-cases\.sh::c1 target=tests/run-all\.sh$')"
k2="$(rr_line_no "$O4" '^PASS .*u1-cases\.sh::c2 target=tests/lib/harness\.sh$')"
if [ -n "$c_ln" ] && [ -n "$f_ln" ] && [ -n "$k1" ] && [ -n "$k2" ] &&
   [ "$c_ln" -lt "$f_ln" ] && [ "$k1" -eq $((f_ln + 1)) ] && [ "$k2" -eq $((f_ln + 2)) ]; then
    fx_pass "A1. child stdout, then 'PASS: <file>', then its case lines c1, c2 in seq order"
else
    fx_fail "A1. block order wrong (child=$c_ln file=$f_ln c1=$k1 c2=$k2)"
fi
if [ -s "$O1" ] && cmp -s "$O1" "$O4" && [ "$RC1" = "$RC4" ] && [ -n "$k1" ]; then
    fx_pass "A2. stdout is byte-identical at -j 1 and -j 4 (case lines included)"
else
    fx_fail "A2. -j 1 and -j 4 stdout differ (rc $RC1/$RC4)"
    diff "$O1" "$O4" | head -n 10
fi
case_end

case_begin "file-pseudo-case" "bin/lib/run-all-report.sh"
grep -qE '^PASS .*u2-nocases\.sh::\(file\) target=.*u2-nocases\.sh$' "$O4"
fx_check $? "A3. a unit without case records gets a synthesized '<STATE> <file>::(file)' line"
if grep -qE '^PASS .*u3-fail-onlypass\.sh::c1 target=tests/run-all\.sh$' "$O4" &&
   grep -qE '^FAIL .*u3-fail-onlypass\.sh::\(file\) target=.*u3-fail-onlypass\.sh$' "$O4"; then
    fx_pass "A4. exit 1 with only PASS records adds a synthetic 'FAIL <file>::(file)'"
else
    fx_fail "A4. synthetic (file) FAIL missing for u3-fail-onlypass"
fi
case_end

case_begin "open-and-unobserved-resolution" "bin/lib/run-all-report.sh"
if grep -qE '^FAIL .*u4-open-fail\.sh::c-open target=tests/run-all\.sh$' "$O4" &&
   ! grep -qE '^[A-Z]+ .*u4-open-fail\.sh::\(file\)' "$O4"; then
    fx_pass "A5. an OPEN case in a failing unit resolves to FAIL (no extra (file) FAIL)"
else
    fx_fail "A5. OPEN case in a failing unit not reported as FAIL"
fi
if grep -qE '^PASS .*u5-open-pass\.sh::c-done ' "$O4" && ! grep -qE 'u5-open-pass\.sh::c-open' "$O4"; then
    fx_pass "A6. an OPEN case in a passing unit is dropped; its closed sibling is kept"
else
    fx_fail "A6. OPEN case in a passing unit not dropped (or c-done missing)"
fi
if ! grep -qE 'u6-unobserved\.sh::c-quiet' "$O4" &&
   grep -qE '^PASS .*u6-unobserved\.sh::\(file\) ' "$O4"; then
    fx_pass "A7. an UNOBSERVED case is dropped and the unit falls back to its (file) line"
else
    fx_fail "A7. UNOBSERVED case printed, or no (file) fallback for u6-unobserved"
fi
case_end

# WHY: `fail` records the open case at once, so a file that exits 0 (or 77) before closing the case cannot
# report a failed case as a pass or a skip.
case_begin "failed-open-case-survives-a-clean-exit" "tests/lib/harness.sh"
for a8 in u7-open-failed-exit0 u8-open-failed-exit77; do
  if grep -qE "^FAIL: .*$a8\.sh" "$O4" && grep -qE "^FAIL .*$a8\.sh::c-bad target=tests/run-all\.sh\$" "$O4"; then
    fx_pass "A8. $a8: the file and its unfinished failed case are both FAIL"
  else
    fx_fail "A8. $a8: a failed case left open was not reported as FAIL"
  fi
done
case_end

[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$O4" 40
fx_finish
