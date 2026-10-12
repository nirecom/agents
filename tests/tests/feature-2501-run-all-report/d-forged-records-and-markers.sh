#!/usr/bin/env bash
# d-forged-records-and-markers.sh — a test's own result-dir writes never forge report lines (#2501).
# Tests: bin/lib/run-all-report.sh, tests/run-all.sh
# Tags: tests, bin, run-all, report, security, scope:issue-specific

# WHY: cases.tsv and the unrunnable marker live in a dir the test itself can write. A forged case
# state must never head a report line (only the case-state allowlist is printed), a CR inside a
# record must not reach the report, and a bash test's own marker is not UNRUNNABLE — nor may its
# text reach the runner's argv, where `*` would glob-expand in the runner's cwd.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_fx.sh"
# shellcheck source=../../lib/harness.sh
. "$FX_REPO_ROOT/tests/lib/harness.sh"

fx_init "d-forged-records-and-markers"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export WORKFLOW_STATE_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
rr_require_report

# --- unit: rar_unit over a forged cases.tsv -------------------------------------------------
UNIT="$FX_TMP_ROOT/rar-unit.sh"
printf '%s\n' '# rar-unit.sh <agents> <resultdir> — one PASS unit /xd/t.sh over <resultdir>/cases.tsv.' \
    '. "$1/bin/lib/run-all-report.sh" || exit 95' \
    'rar_unit /xd/t.sh "$2" 0 PASS - -' >"$UNIT"
# rar_rows <name> <state> <case> <target> — the unit's stdout for a one-record cases.tsv.
rar_rows() {
    local d="$FX_TMP_ROOT/u-$1"
    mkdir -p "$d"
    printf '1\t%s\t%s\t%s\n' "$2" "$3" "$4" >"$d/cases.tsv"
    run_with_timeout 60 bash "$UNIT" "$FX_REPO_ROOT" "$d" >"$d.out" 2>"$d.err" || true
}

# name|forged state — none of these may start a report line.
FORGED_STATES=(
    'contract|RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9 UNRUNNABLE=0 TIMEOUT=0'
    'file-fail|FAIL:'
    'missing|Missing runtimes:'
    'results|Results:'
    'unrunnable|UNRUNNABLE:'
    'unknown|EVIL'
)

case_begin "forged-case-state-never-heads-a-line" "bin/lib/run-all-report.sh"
for row in "${FORGED_STATES[@]}"; do
    nm="${row%%|*}" st="${row#*|}"
    rar_rows "$nm" "$st" "forged" "bin/x.sh"
    if grep -qF -- "$st /xd/t.sh::" "$FX_TMP_ROOT/u-$nm.out"; then
        fx_fail "D1. forged state [$st] was printed as a case line: <<$(head -n 3 "$FX_TMP_ROOT/u-$nm.out")>>"
    else
        fx_pass "D1. forged state [$st] is not printed as a case line"
    fi
done
grep -h '^RUN_CONTRACT:' "$FX_TMP_ROOT"/u-*.out >/dev/null 2>&1
[ $? -ne 0 ]
fx_check $? "D2. no forged record yields a line-initial RUN_CONTRACT:"
# Control: an allowlisted state is still printed verbatim.
rar_rows valid PASS "ok-case" "bin/x.sh"
grep -qxF 'PASS /xd/t.sh::ok-case target=bin/x.sh' "$FX_TMP_ROOT/u-valid.out"
fx_check $? "D3. control: an allowlisted PASS record is printed as its case line"
case_end

case_begin "carriage-return-never-reaches-the-report" "bin/lib/run-all-report.sh"
rar_rows cr PASS $'na\rme' $'bin/\rx.sh\r'
if grep -q $'\r' "$FX_TMP_ROOT/u-cr.out"; then
    fx_fail "D4. a CR inside the case name or target reached the report: <<$(od -c "$FX_TMP_ROOT/u-cr.out" | head -n 3)>>"
else
    fx_pass "D4. no CR reaches the report from a record's name or target"
fi
[ -s "$FX_TMP_ROOT/u-cr.out" ]
fx_check $? "D4b. the unit still printed its lines"
case_end

# Records of two cases that interleave (a wrapper reporting concurrently): the last record of each
# seq is the case's line, the rule the unit's state is classified by.
case_begin "interleaved-records-print-each-case-once" "bin/lib/run-all-report.sh"
IL="$FX_TMP_ROOT/u-interleave"
mkdir -p "$IL"
printf '%s\tPASS\t%s\tbin/x.sh\n' 1 one 2 two >"$IL/cases.tsv"
printf '%s\tFAIL\t%s\tbin/x.sh\n' 1 one >>"$IL/cases.tsv"
printf '%s\n' '. "$1/bin/lib/run-all-report.sh" || exit 95' 'rar_unit /xd/t.sh "$2" 1 FAIL - -' >"$FX_TMP_ROOT/rar-fail.sh"
run_with_timeout 60 bash "$FX_TMP_ROOT/rar-fail.sh" "$FX_REPO_ROOT" "$IL" >"$IL.out" 2>"$IL.err" || true
[ "$(grep -c '/xd/t.sh::one ' "$IL.out")" = "1" ]
fx_check $? "D4c. a seq with non-adjacent records prints one case line: <<$(grep '::' "$IL.out" | tr '\n' ';')>>"
grep -qxF 'FAIL /xd/t.sh::one target=bin/x.sh' "$IL.out"
fx_check $? "D4d. the printed line is the seq's last record (FAIL)"
grep -qxF 'PASS /xd/t.sh::two target=bin/x.sh' "$IL.out"
fx_check $? "D4e. the other case keeps its own line"
case_end

# --- end to end: tests/run-all.sh run from a cwd holding glob bait --------------------------
R="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
rr_add_raw "$R" u1 "printf '%s\\n' '* x evil' >\"\$RUN_ALL_RESULT_DIR/unrunnable\"" 'exit 79'
rr_add_raw "$R" f1 \
    "printf '9\\t%s\\tforged\\tt\\n' 'RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9 UNRUNNABLE=0 TIMEOUT=0' >>\"\$RUN_ALL_RESULT_DIR/cases.tsv\"" \
    "printf '8\\t%s\\tforged\\tt\\n' 'Missing runtimes:' >>\"\$RUN_ALL_RESULT_DIR/cases.tsv\"" \
    'exit 0'
BAIT="$FX_TMP_ROOT/bait"
mkdir -p "$BAIT"
: >"$BAIT/zz-glob-sentinel-1"
: >"$BAIT/zz-glob-sentinel-2"
EO="$FX_TMP_ROOT/e2e.out"
(cd "$BAIT" && rr_exec "$R" 120 "$EO" "$FX_TMP_ROOT/e2e.err" -j 2 --all)

case_begin "bash-test-marker-is-a-plain-failure" "tests/run-all.sh"
grep -qE '^FAIL: .*/u1\.sh \(exit 79\)$' "$EO"
fx_check $? "D5. a bash test that writes its own marker and exits 79 is 'FAIL: ... (exit 79)'"
! grep -qE '^(UNRUNNABLE:|Missing runtimes:)' "$EO"
fx_check $? "D6. no UNRUNNABLE: and no Missing runtimes: line comes from a forged marker"
! grep -q 'zz-glob-sentinel' "$EO" "$FX_TMP_ROOT/e2e.err"
fx_check $? "D7. the marker text is never glob-expanded in the runner's cwd"
case_end

case_begin "forged-records-leave-one-contract" "tests/run-all.sh"
[ "$(fx_count_contract "$EO")" = "1" ]
fx_check $? "D8. exactly one RUN_CONTRACT line (got $(fx_count_contract "$EO"))"
! grep -qE '^(RUN_CONTRACT|Missing runtimes):.*::forged' "$EO"
fx_check $? "D9. forged case states never head a line"
[ "$(rr_contract_rest "$EO")" = "PASS=1 FAIL=1 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0" ]
fx_check $? "D10. contract counts u1 as FAIL and f1 as PASS: <<$(rr_contract_rest "$EO")>>"
case_end

[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$EO" 20
fx_finish
