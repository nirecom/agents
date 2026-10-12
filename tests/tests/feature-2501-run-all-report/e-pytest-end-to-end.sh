#!/usr/bin/env bash
# e-pytest-end-to-end.sh — a real .py test through the real runner: registry dispatch → wrapper → report (#2501).
# Tests: tests/run-all.sh, bin/lib/run-all-launch.sh, bin/lib/run-all-report.sh, bin/lib/test-wrappers/pytest.py
# Tags: tests, bin, run-all, report, pytest, uv, scope:issue-specific

# WHY: the launch test drives a fake uv and the wrapper test calls the wrapper directly, so neither
# sees a break between the registry entry, the wrapper's case records and the contract line. Here
# the real uv runs the real wrapper under tests/run-all.sh.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_fx.sh"
# shellcheck source=../../lib/harness.sh
. "$FX_REPO_ROOT/tests/lib/harness.sh"

command -v uv >/dev/null 2>&1 || { echo "SKIP: uv not on PATH"; exit 77; }

fx_init "e-pytest-end-to-end"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export WORKFLOW_STATE_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
rr_require_report

# --- a passing file: one pass, one skip ----------------------------------------
P="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
printf '%s\n' 'import pytest' '' '' 'def test_ok():' '    assert True' '' '' \
    '@pytest.mark.skip(reason="fixture")' 'def test_skipped():' '    assert False' >"$P/tests/bin/test_e2e_ok.py"
PO="$FX_TMP_ROOT/py-ok.out"
rr_exec "$P" 240 "$PO" "$FX_TMP_ROOT/py-ok.err" -j 1 --all; PRC=$?

case_begin "passing-pytest-file-reports-cases-and-contract" "tests/run-all.sh"
[ "$PRC" -eq 0 ]
fx_check $? "E1. a passing .py file: runner exit 0 (rc=$PRC)"
[ "$(grep -cE '^PASS: .*test_e2e_ok\.py$' "$PO")" = "1" ]
fx_check $? "E2. one file-level 'PASS: <file>' line"
[ "$(grep -cE '^PASS .*test_e2e_ok\.py::.*test_ok target=.*test_e2e_ok\.py$' "$PO")" = "1" ] &&
    [ "$(grep -cE '^SKIP .*test_e2e_ok\.py::.*test_skipped target=.*test_e2e_ok\.py$' "$PO")" = "1" ]
fx_check $? "E3. one case line per pytest test: PASS …::test_ok and SKIP …::test_skipped"
[ "$(grep -cE '^(PASS|FAIL|SKIP|XFAIL|XPASS) [^:]*test_e2e_ok\.py::' "$PO")" = "2" ] && ! grep -qE '::\(file\) ' "$PO"
fx_check $? "E4. exactly the two wrapper records are printed, no synthetic (file) line"
[ "$(rr_contract_rest "$PO")" = "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0" ] && [ "$(fx_count_contract "$PO")" = "1" ]
fx_check $? "E5. contract: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 (got <<$(rr_contract_rest "$PO")>>)"
case_end

# --- a failing file beside a passing one ---------------------------------------
F="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
printf '%s\n' 'def test_ok():' '    assert True' '' '' 'def test_ng():' '    assert 1 == 2' >"$F/tests/bin/test_e2e_ng.py"
FO="$FX_TMP_ROOT/py-ng.out"
rr_exec "$F" 240 "$FO" "$FX_TMP_ROOT/py-ng.err" -j 1 --all; FRC=$?

case_begin "failing-pytest-file-reports-fail-case-and-exit-1" "tests/run-all.sh"
[ "$FRC" -eq 1 ]
fx_check $? "E6. a failing .py file: runner exit 1 (rc=$FRC)"
[ "$(grep -cE '^FAIL: .*test_e2e_ng\.py \(exit 1\)$' "$FO")" = "1" ]
fx_check $? "E7. one file-level 'FAIL: <file> (exit 1)' line"
[ "$(grep -cE '^FAIL .*test_e2e_ng\.py::.*test_ng target=' "$FO")" = "1" ] &&
    [ "$(grep -cE '^PASS .*test_e2e_ng\.py::.*test_ok target=' "$FO")" = "1" ] && ! grep -qE '::\(file\) ' "$FO"
fx_check $? "E8. the failing case is named (FAIL …::test_ng) beside PASS …::test_ok, no synthetic (file) line"
[ "$(rr_contract_rest "$FO")" = "PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0" ]
fx_check $? "E9. contract: PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0 (got <<$(rr_contract_rest "$FO")>>)"
case_end

[ "$FX_ERRORS" -eq 0 ] || { fx_show_tail "$PO" 20; fx_show_tail "$FX_TMP_ROOT/py-ok.err" 20; fx_show_tail "$FO" 20; }
fx_finish
