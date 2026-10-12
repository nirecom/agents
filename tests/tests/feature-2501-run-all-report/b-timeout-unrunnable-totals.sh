#!/usr/bin/env bash
# b-timeout-unrunnable-totals.sh — TIMEOUT / UNRUNNABLE units and the 5-field / 6-field tails (#2501).
# Tests: bin/lib/run-all-report.sh, tests/run-all.sh
# Tags: tests, bin, run-all, report, scope:issue-specific

# WHY: a unit killed by its timeout is a FAIL that also says TIMEOUT; a unit whose runtime is
# missing never ran, so it is UNRUNNABLE — outside EXECUTED, outside FAIL, and named once in
# "Missing runtimes:". The exit code still turns only on FAIL.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_fx.sh"
# shellcheck source=../../lib/harness.sh
. "$FX_REPO_ROOT/tests/lib/harness.sh"

fx_init "b-timeout-unrunnable-totals"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export WORKFLOW_STATE_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
rr_require_report

MISSING_TOOL="no-such-tool-2501"
RR_SET_REQUIRES='const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,"utf8"));for(const e of j.entries){if(e.id==="pytest"){e.launch.requires=process.argv[2]}}fs.writeFileSync(p,JSON.stringify(j,null,2))'
# rr_unrunnable_root — a root whose pytest row requires a tool no host has, plus one test_x.py.
rr_unrunnable_root() {
    local root
    root="$(rr_new_root)" || return 1
    node -e "$RR_SET_REQUIRES" "$(np "$root/hooks/lib/test-language-registry.json")" "$MISSING_TOOL" || return 1
    printf 'def test_x():\n    assert True\n' >"$root/tests/bin/test_x.py"
    echo "$root"
}

# --- fixture 1: one of every state ------------------------------------------
M="$(rr_unrunnable_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
fx_add_dummy "$M" p1-pass
fx_add_dummy "$M" f1-fail --exit 1
fx_add_dummy "$M" s1-skip --exit 77
rr_add_raw "$M" t1-timeout 'sleep 10' 'exit 0'
MO="$FX_TMP_ROOT/mix.out"
# The per-file bound comes from the caller's env (bash has no registry timeout); the other units finish well inside 2 s.
( export RUN_ALL_TIMEOUT_SECONDS=2; rr_exec "$M" 120 "$MO" "$FX_TMP_ROOT/mix.err" -j 4 --all ); MRC=$?

case_begin "timeout-unit" "bin/lib/run-all-report.sh"
f_ln="$(rr_line_no "$MO" '^FAIL: .*t1-timeout\.sh \(exit 124\)$')"
t_ln="$(rr_line_no "$MO" '^TIMEOUT: .*t1-timeout\.sh \(2s\)$')"
if [ -n "$f_ln" ] && [ -n "$t_ln" ] && [ "$t_ln" -eq $((f_ln + 1)) ]; then
    fx_pass "B1. a unit under RUN_ALL_TIMEOUT_SECONDS=2 prints 'FAIL: s (exit 124)' then 'TIMEOUT: s (2s)'"
else
    fx_fail "B1. TIMEOUT lines missing or out of order (fail=$f_ln timeout=$t_ln)"
fi
case_end

case_begin "unrunnable-unit" "bin/lib/run-all-report.sh"
grep -qE "^UNRUNNABLE: .*test_x\.py \(missing: $MISSING_TOOL\)$" "$MO"
fx_check $? "B2. a unit whose requires is missing prints 'UNRUNNABLE: s (missing: $MISSING_TOOL)'"
grep -qxF "Missing runtimes: $MISSING_TOOL (1 file)" "$MO"
fx_check $? "B3. 'Missing runtimes: $MISSING_TOOL (1 file)' is printed when UNRUNNABLE>0"
! grep -qE '^[A-Z]+ .*test_x\.py::' "$MO" && [ -n "$(rr_line_no "$MO" '^UNRUNNABLE: ')" ]
fx_check $? "B4. an UNRUNNABLE unit has no case lines"
case_end

case_begin "totals-and-contract" "tests/run-all.sh"
grep -qxF 'Results: PASS=1  FAIL=2  SKIP=1  UNRUNNABLE=1  TIMEOUT=1' "$MO"
fx_check $? "B5. Results: carries 5 fields; TIMEOUT counts inside FAIL"
REST="$(rr_contract_rest "$MO")"
NF="$(printf '%s\n' "$REST" | awk '{ print NF }')"
if [ "$REST" = "PASS=1 FAIL=2 SKIP=1 EXECUTED=4 UNRUNNABLE=1 TIMEOUT=1" ] && [ "$NF" = "6" ]; then
    fx_pass "B6. RUN_CONTRACT has exactly 6 fields and EXECUTED=p+f+s excludes UNRUNNABLE"
else
    fx_fail "B6. RUN_CONTRACT mismatch (fields=$NF): <<$REST>>"
fi
[ "$MRC" -eq 1 ]
fx_check $? "B7. FAIL>0 exits 1 (got $MRC)"
case_end

# --- fixture 2: UNRUNNABLE without FAIL exits 0 ---------------------------
U="$(rr_unrunnable_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
fx_add_dummy "$U" p1-pass
UO="$FX_TMP_ROOT/unr.out"
rr_exec "$U" 90 "$UO" "$FX_TMP_ROOT/unr.err" -j 4 --all; URC=$?
# --- fixture 3: no UNRUNNABLE --------------------------------------------
G="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
fx_add_dummy "$G" p1-pass
GO="$FX_TMP_ROOT/green.out"
rr_exec "$G" 90 "$GO" "$FX_TMP_ROOT/green.err" -j 4 --all; GRC=$?

case_begin "exit-and-missing-runtimes-presence" "tests/run-all.sh"
if [ "$URC" -eq 0 ] && [ "$(rr_contract_rest "$UO")" = "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=1 TIMEOUT=0" ] &&
   grep -qxF "Missing runtimes: $MISSING_TOOL (1 file)" "$UO"; then
    fx_pass "B8. UNRUNNABLE=1 with FAIL=0 exits 0 and still names the missing runtime"
else
    fx_fail "B8. rc=$URC contract=<<$(rr_contract_rest "$UO")>>"
fi
if [ "$GRC" -eq 0 ] && [ "$(rr_contract_rest "$GO")" = "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0" ] &&
   ! grep -q '^Missing runtimes:' "$GO"; then
    fx_pass "B9. UNRUNNABLE=0: no 'Missing runtimes:' line, 6-field contract, exit 0"
else
    fx_fail "B9. rc=$GRC contract=<<$(rr_contract_rest "$GO")>> missing-line=$(grep -c '^Missing runtimes:' "$GO")"
fi
case_end

# A TIMEOUT unit writes no records, so it gets one (file) case line in state FAIL (plan D5-1),
# directly after its TIMEOUT: line — never a TIMEOUT case state.
case_begin "timeout-unit-file-line" "bin/lib/run-all-report.sh"
tf_n="$(grep -cE '^FAIL .*t1-timeout\.sh::\(file\) target=.*t1-timeout\.sh$' "$MO")"
tf_ln="$(rr_line_no "$MO" '^FAIL .*t1-timeout\.sh::\(file\) target=.*t1-timeout\.sh$')"
tt_ln="$(rr_line_no "$MO" '^TIMEOUT: .*t1-timeout\.sh \(2s\)$')"
if [ "$tf_n" = "1" ] && [ -n "$tf_ln" ] && [ -n "$tt_ln" ] && [ "$tf_ln" -eq $((tt_ln + 1)) ]; then
    fx_pass "B10. the TIMEOUT unit prints one 'FAIL s::(file) target=s' line right after 'TIMEOUT:'"
else
    fx_fail "B10. (file) line count=$tf_n at line=$tf_ln, TIMEOUT: at line=$tt_ln"
fi
! grep -qE '^TIMEOUT .*t1-timeout\.sh::' "$MO"
fx_check $? "B11. no case line carries the state TIMEOUT"
case_end

# --- fixture 4: two different missing runtimes -----------------------------
MISSING_TOOL_B="no-such-tool-2501-b"
RR_SET_REQUIRES_BY_ID='const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,"utf8"));for(const e of j.entries){if(e.id===process.argv[2]){e.launch.requires=process.argv[3]}}fs.writeFileSync(p,JSON.stringify(j,null,2))'
L="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
node -e "$RR_SET_REQUIRES_BY_ID" "$(np "$L/hooks/lib/test-language-registry.json")" pytest "$MISSING_TOOL" || fx_fail "registry edit (pytest) failed"
node -e "$RR_SET_REQUIRES_BY_ID" "$(np "$L/hooks/lib/test-language-registry.json")" pester "$MISSING_TOOL_B" || fx_fail "registry edit (pester) failed"
printf 'def test_x():\n    assert True\n' >"$L/tests/bin/test_x.py"
printf 'def test_y():\n    assert True\n' >"$L/tests/bin/test_y.py"
printf "Describe 'z' {\n  It 'z' { 1 | Should -Be 1 }\n}\n" >"$L/tests/bin/z.Tests.ps1"
fx_add_dummy "$L" p1-pass
LO="$FX_TMP_ROOT/labels.out"
rr_exec "$L" 120 "$LO" "$FX_TMP_ROOT/labels.err" -j 4 --all; LRC=$?

# Labels follow the order in which their first UNRUNNABLE: line appears (plan D5-1).
case_begin "missing-runtimes-multiple-labels" "bin/lib/run-all-report.sh"
first_label="$(awk '/^UNRUNNABLE: /{ s=$0; sub(/.*\(missing: /, "", s); sub(/\)$/, "", s); print s; exit }' "$LO")"
if [ "$first_label" = "$MISSING_TOOL_B" ]; then
    want_line="Missing runtimes: $MISSING_TOOL_B (1 file), $MISSING_TOOL (2 files)"
else
    want_line="Missing runtimes: $MISSING_TOOL (2 files), $MISSING_TOOL_B (1 file)"
fi
if [ -n "$first_label" ] && grep -qxF "$want_line" "$LO"; then
    fx_pass "B12. two missing runtimes share one line, in first-appearance order with per-label counts"
else
    fx_fail "B12. want <<$want_line>> (first UNRUNNABLE label=<<$first_label>>); got <<$(grep '^Missing runtimes:' "$LO")>>"
fi
[ "$(grep -c '^Missing runtimes:' "$LO")" = "1" ]
fx_check $? "B13. exactly one 'Missing runtimes:' line"
if [ "$LRC" -eq 0 ] && [ "$(rr_contract_rest "$LO")" = "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=3 TIMEOUT=0" ]; then
    fx_pass "B14. three UNRUNNABLE units across two runtimes: UNRUNNABLE=3, exit 0"
else
    fx_fail "B14. rc=$LRC contract=<<$(rr_contract_rest "$LO")>>"
fi
case_end

[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$MO" 30
fx_finish
