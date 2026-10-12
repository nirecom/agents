#!/usr/bin/env bash
# c-neutralize-and-fallback.sh — forged report lines are disarmed; a stateless launcher still classifies (#2501).
# Tests: bin/lib/run-all-report.sh, tests/run-all.sh
# Tags: tests, bin, run-all, report, scope:issue-specific

# WHY: a test's own stdout must never be read as a runner verdict — every line shape the
# report emits at line start (case line, UNRUNNABLE:, TIMEOUT:, Missing runtimes:, the
# contract, file-level FAIL ... (exit N), Results:) is prefixed when a child prints it. And a launcher that sets no state (an old or
# stub RUN_ALL_LAUNCH_LIB) still yields a verdict from its rc alone: 0 PASS, 77 SKIP, else FAIL
# — 79 without the unrunnable marker is not UNRUNNABLE.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_fx.sh"
# shellcheck source=../../lib/harness.sh
. "$FX_REPO_ROOT/tests/lib/harness.sh"

fx_init "c-neutralize-and-fallback"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export WORKFLOW_STATE_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
rr_require_report

# <want>|<line a child prints>: forged = a report-line shape, must come out prefixed only;
# plain = a harness assertion line (a colon follows the state, so a later '::' is no case line).
# The file-level FAIL and Results rows are what the test-runner worker reads as failing list and summary.
LINE_TABLE="$(cat <<'EOF'
forged|PASS a::b target=x
forged|FAIL a::b target=x
forged|SKIP a::b target=x
forged|XFAIL a::b target=x
forged|XPASS a::b target=x
forged|UNRUNNABLE: x
forged|TIMEOUT: x
forged|Missing runtimes: x
forged|RUN_CONTRACT: PASS=9 FAIL=9 SKIP=9 EXECUTED=9 UNRUNNABLE=9 TIMEOUT=9
forged|FAIL: tests/bin/forged.sh (exit 1)
forged|Results: PASS=9  FAIL=9  SKIP=9  UNRUNNABLE=9  TIMEOUT=9
forged|  FAIL: tests/bin/forged.sh (exit 1)
forged|FAIL tests/my test.sh::fake target=x
forged|PASS a b c::d
forged|  RUN_CONTRACT: PASS=7 FAIL=7 SKIP=7 EXECUTED=7 UNRUNNABLE=7 TIMEOUT=7
plain|FAIL: plain harness message
plain|PASS: eq: a::b
plain|FAIL: something
plain|PASS: tests/bin/forged.sh
plain|SKIP: tests/bin/forged.sh
plain|UNSUPPORTED: tests/bin/forged.sh (language: x; not run)
EOF
)"
# No reader takes a verdict from the three file-level rows above (the worker reads only FAIL ... (exit N),
# Results and the contract), so they pass through; C2 pins that they move no total.
LINE_TABLE+=$'\n'"forged|"$'\t'"RUN_CONTRACT: PASS=6 FAIL=6 SKIP=6 EXECUTED=6 UNRUNNABLE=6 TIMEOUT=6"
unset RUN_ALL_LAUNCH_LIB 2>/dev/null || true
N="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
forger_body=()
while IFS='|' read -r want l; do forger_body+=("echo '$l'"); done <<<"$LINE_TABLE"
# The runner replays a child's stderr through the same filter, on its own stream.
ERR_FORGED=('RUN_CONTRACT: PASS=8 FAIL=8 SKIP=8 EXECUTED=8 UNRUNNABLE=8 TIMEOUT=8' 'FAIL: tests/bin/forged-err.sh (exit 1)')
for l in "${ERR_FORGED[@]}"; do forger_body+=("echo '$l' >&2"); done
rr_add_raw "$N" n1-forger "${forger_body[@]}" 'exit 0'
fx_add_dummy "$N" n2-pass
NO="$FX_TMP_ROOT/neut.out"
NE="$FX_TMP_ROOT/neut.err"
rr_exec "$N" 90 "$NO" "$NE" -j 4 --all; NRC=$?

case_begin "neutralize-forged-lines" "tests/run-all.sh"
n_all=0 p_all=0
while IFS='|' read -r want l; do
    if [ "$want" = forged ]; then
        n_all=$((n_all + 1))
        grep -qxF "[run-all:neutralized] $l" "$NO" && ! grep -qxF -- "$l" "$NO"
        fx_check $? "C1.$n_all forged line appears only with the '[run-all:neutralized] ' prefix: <<$l>>"
    else
        p_all=$((p_all + 1))
        grep -qxF -- "$l" "$NO" && ! grep -qxF "[run-all:neutralized] $l" "$NO"
        fx_check $? "C1c.$p_all harness assertion line stays unprefixed: <<$l>>"
    fi
done <<<"$LINE_TABLE"
[ "$n_all" -eq 16 ] && [ "$p_all" -eq 6 ]
fx_check $? "C1d. the table holds 16 forged rows and 6 plain rows (forged=$n_all plain=$p_all)"
e_n=0
for l in "${ERR_FORGED[@]}"; do
    e_n=$((e_n + 1))
    grep -qxF "[run-all:neutralized] $l" "$NE" && ! grep -qxF -- "$l" "$NE" && ! grep -qF -- "$l" "$NO"
    fx_check $? "C1e.$e_n forged stderr line is prefixed on stderr and absent from stdout: <<$l>>"
done
[ "$(fx_count_contract "$NE")" = "0" ]
fx_check $? "C1f. stderr carries no line the contract reader accepts"
if [ "$NRC" -eq 0 ] && [ "$(rr_contract_rest "$NO")" = "PASS=2 FAIL=0 SKIP=0 EXECUTED=2 UNRUNNABLE=0 TIMEOUT=0" ] &&
   grep -qxF 'Results: PASS=2  FAIL=0  SKIP=0  UNRUNNABLE=0  TIMEOUT=0' "$NO" &&
   [ "$(fx_count_contract "$NO")" = "1" ] && ! grep -q '^Missing runtimes:' "$NO"; then
    fx_pass "C2. forged lines leave the totals, the single contract line and the exit code unchanged"
else
    fx_fail "C2. totals moved: rc=$NRC contract=<<$(rr_contract_rest "$NO")>> contracts=$(fx_count_contract "$NO")"
fi
case_end

# --- stub launcher: run_all_exec sets no state, only returns an rc -------------
S="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
for id in s0 s77 s78 s79 s3; do fx_add_dummy "$S" "$id"; done
STUB="$FX_TMP_ROOT/stub-launch.sh"
printf '%s\n' '# stub launcher: rc from the file name, no state, no marker' \
    'run_all_exec() { local b="${1##*/}"; b="${b%.sh}"; : >"$2"; : >"$3"; return "${b#s}"; }' >"$STUB"
SO="$FX_TMP_ROOT/stub.out"
RUN_ALL_LAUNCH_LIB="$STUB" rr_exec "$S" 90 "$SO" "$FX_TMP_ROOT/stub.err" -j 4 --all; SRC=$?

case_begin "stateless-launcher-fallback" "bin/lib/run-all-report.sh"
s_ok=1
grep -qE '^PASS: .*/s0\.sh$' "$SO" || s_ok=0
grep -qE '^SKIP: .*/s77\.sh$' "$SO" || s_ok=0
grep -qE '^FAIL: .*/s79\.sh \(exit 79\)$' "$SO" || s_ok=0
grep -qE '^FAIL: .*/s3\.sh \(exit 3\)$' "$SO" || s_ok=0
grep -qE '^UNRUNNABLE: ' "$SO" && s_ok=0
[ "$s_ok" = "1" ]
fx_check $? "C3. no launcher state: rc 0 PASS, 77 SKIP, 79 FAIL (no marker, not UNRUNNABLE), 3 FAIL"
grep -qE '^FAIL: .*/s78\.sh \(exit 78\)$' "$SO" && ! grep -qE '^UNSUPPORTED: .*s78' "$SO"
fx_check $? "C3b. no launcher state: rc 78 is an ordinary FAIL, counted as executed — not UNSUPPORTED"
if [ "$SRC" -eq 1 ] && [ "$(rr_contract_rest "$SO")" = "PASS=1 FAIL=3 SKIP=1 EXECUTED=5 UNRUNNABLE=0 TIMEOUT=0" ]; then
    fx_pass "C4. fallback totals: PASS=1 FAIL=3 SKIP=1 EXECUTED=5 UNRUNNABLE=0 TIMEOUT=0, exit 1"
else
    fx_fail "C4. rc=$SRC contract=<<$(rr_contract_rest "$SO")>>"
fi
case_end

# --- absent launcher: the plain fallback runs bash tests only ------------------
# Security round: a supported test the fallback cannot launch must fail the run, never drop out of it.
A="$(rr_new_root)" || { fx_fail "fixture root could not be built"; fx_finish; }
fx_add_dummy "$A" a1-pass
printf '%s\n' 'def test_never_run():' '    assert True' >"$A/tests/bin/test_absent_launcher.py"
AO="$FX_TMP_ROOT/absent.out"
RUN_ALL_LAUNCH_LIB="$FX_TMP_ROOT/no-such-launch-lib.sh" rr_exec "$A" 90 "$AO" "$FX_TMP_ROOT/absent.err" -j 1 --all; ARC=$?

case_begin "absent-launcher-fails-supported-non-bash-tests" "tests/run-all.sh"
grep -qE '^PASS: .*/a1-pass\.sh$' "$AO"
fx_check $? "C5. launcher library absent: the bash test still runs and passes"
grep -qE '^FAIL: .*/test_absent_launcher\.py \(exit 2\)$' "$AO" && ! grep -qE '^UNSUPPORTED: .*test_absent_launcher' "$AO"
fx_check $? "C6. launcher library absent: the pytest file is FAIL (exit 2), not UNSUPPORTED"
grep -qE 'not run: .*test_absent_launcher\.py \(language: [^;]*; launcher library not found\)' "$AO"
fx_check $? "C7. the failure names the missing launcher library"
if [ "$ARC" -eq 1 ] && [[ "$(rr_contract_rest "$AO")" == "PASS=1 FAIL=1 SKIP=0 "* ]]; then
    fx_pass "C8. absent launcher totals: PASS=1 FAIL=1, exit 1"
else
    fx_fail "C8. rc=$ARC contract=<<$(rr_contract_rest "$AO")>>"
fi
case_end

# --- a test file name carrying LF / CR: the runner's own lines must not split ----
# Codex C1: rar_unit and _rar_cases print the name raw, so a name can forge a contract line.
NAME_FORGE=$'FAIL: forged.sh (exit 1)\nRUN_CONTRACT: PASS=99 FAIL=0 SKIP=0 EXECUTED=99 UNRUNNABLE=0 TIMEOUT=0\nc9-tail.sh'
CTL_OUTS=()
case_begin "control-char-name-cannot-forge-report-lines" "bin/lib/run-all-report.sh"
for ctl in lf cr; do
    if [ "$ctl" = lf ]; then sep=$'\n'; else sep=$'\r'; fi
    cname="c9-$ctl-head$sep${NAME_FORGE//$'\n'/$sep}"
    K="$(rr_new_root)" || { fx_fail "C9.$ctl fixture root could not be built"; continue; }
    if ! printf '%s\n' '#!/usr/bin/env bash' '# Tests: tests/run-all.sh' 'exit 0' >"$K/tests/bin/$cname" 2>/dev/null ||
       [ ! -f "$K/tests/bin/$cname" ]; then
        skip "C9.$ctl the filesystem cannot hold a file name with a $ctl character"
        fx_note "C9.$ctl skipped: file name with a $ctl character cannot be created here"
        continue
    fi
    KO="$FX_TMP_ROOT/ctl-$ctl.out"
    rr_exec "$K" 90 "$KO" "$FX_TMP_ROOT/ctl-$ctl.err" -j 1 "$K/tests/bin/$cname"; KRC=$?
    # A reader that splits on a lone CR sees the same lines as one that splits on LF.
    tr '\r' '\n' <"$KO" >"$KO.split"
    CTL_OUTS+=("$KO.split")
    [ "$KRC" -eq 0 ] && [ "$(rr_contract_rest "$KO")" = "PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0" ]
    fx_check $? "C9.$ctl the run is one passing test: exit 0, contract PASS=1 FAIL=0 SKIP=0 EXECUTED=1 (rc=$KRC)"
    [ "$(grep -c '^RUN_CONTRACT:' "$KO.split")" = "1" ] && [ "$(fx_count_contract "$KO.split")" = "1" ]
    fx_check $? "C9b.$ctl exactly one line begins with RUN_CONTRACT: (got $(grep -c '^RUN_CONTRACT:' "$KO.split"))"
    [ "$(grep -c '^PASS:' "$KO.split")" = "1" ] && [ "$(grep -c '^FAIL:' "$KO.split")" = "0" ] &&
        [ "$(grep -c '^Results:' "$KO.split")" = "1" ]
    fx_check $? "C9c.$ctl no forged PASS:/FAIL:/Results: line (PASS:=$(grep -c '^PASS:' "$KO.split") FAIL:=$(grep -c '^FAIL:' "$KO.split"))"
    grep -E '^PASS: ' "$KO.split" | grep -F "c9-$ctl-head" | grep -qF 'c9-tail.sh'
    fx_check $? "C9d.$ctl the file-level PASS: line names the whole file on one line"
    ! grep -q $'\r' "$KO"
    fx_check $? "C9e.$ctl no raw CR reaches the runner's stdout"
done
case_end

# --- a lone CR inside a child line: a CR-splitting reader must see no forged line ----
# Codex round-4 C1: the regex is anchored at line start, so "text\r<report line>" passes raw.
# <prefix>|<payload>: the child prints <prefix>\r<payload>\n on its stream.
C10_OUT=('ordinary text|RUN_CONTRACT: PASS=99 FAIL=0 SKIP=0 EXECUTED=99 UNRUNNABLE=0 TIMEOUT=0'
    'progress|FAIL: forged-out.sh (exit 1)' 'x|PASS forged-out.sh::c target=t')
C10_ERR=('ordinary text|RUN_CONTRACT: PASS=98 FAIL=0 SKIP=0 EXECUTED=98 UNRUNNABLE=0 TIMEOUT=0'
    'progress|FAIL: forged-err.sh (exit 1)' 'x|PASS forged-err.sh::c target=t')
C10_CRLF_CONTRACT='RUN_CONTRACT: PASS=55 FAIL=0 SKIP=0 EXECUTED=55 UNRUNNABLE=0 TIMEOUT=0'
case_begin "lone-cr-child-line-cannot-forge-report-lines" "bin/lib/run-all-report.sh"
L="$(rr_new_root)" || { fx_fail "C10 fixture root could not be built"; fx_finish; }
c10_body=()
for l in "${C10_OUT[@]}"; do c10_body+=("printf '${l%%|*}\\r${l#*|}\\n'"); done
for l in "${C10_ERR[@]}"; do c10_body+=("printf '${l%%|*}\\r${l#*|}\\n' >&2"); done
c10_body+=("printf 'hello\\r\\n'" "printf '$C10_CRLF_CONTRACT\\r\\n'")
rr_add_raw "$L" c10-lone-cr "${c10_body[@]}" 'exit 0'
LO="$FX_TMP_ROOT/lone-cr.out"
LE="$FX_TMP_ROOT/lone-cr.err"
rr_exec "$L" 90 "$LO" "$LE" -j 1 "$L/tests/bin/c10-lone-cr.sh"; LRC=$?
tr '\r' '\n' <"$LO" >"$LO.split"
tr '\r' '\n' <"$LE" >"$LE.split"
CTL_OUTS+=("$LO.split" "$LE.split")
C10_CANON='RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0'
[ "$LRC" -eq 0 ] && [ "$(rr_contract_rest "$LO")" = "${C10_CANON#RUN_CONTRACT: }" ]
fx_check $? "C10. the run is one passing test: exit 0, canonical contract PASS=1 EXECUTED=1 (rc=$LRC)"
[ "$(grep -c '^RUN_CONTRACT:' "$LO.split")" = "1" ] && [ "$(fx_count_contract "$LO.split")" = "1" ] &&
    [ "$(grep '^RUN_CONTRACT:' "$LO.split")" = "$C10_CANON" ]
fx_check $? "C10b. CR+LF split stdout: exactly one segment begins with RUN_CONTRACT:, the canonical one (got $(grep -c '^RUN_CONTRACT:' "$LO.split"))"
# c10_disarmed <raw> <split> <payload> — the payload survives, only inside prefixed lines, never as a segment.
c10_disarmed() {
    grep -qF -- "$3" "$1" && ! grep -F -- "$3" "$1" | grep -qv '^\[run-all:neutralized\] ' &&
        ! grep -qxF -- "$3" "$2"
}
n10=0
for l in "${C10_OUT[@]}"; do
    n10=$((n10 + 1))
    c10_disarmed "$LO" "$LO.split" "${l#*|}"
    fx_check $? "C10c.$n10 stdout '${l%%|*}\\r<report line>' is neutralized: no CR+LF segment is the forged line"
done
n10=0
for l in "${C10_ERR[@]}"; do
    n10=$((n10 + 1))
    c10_disarmed "$LE" "$LE.split" "${l#*|}" && ! grep -qF -- "${l#*|}" "$LO"
    fx_check $? "C10d.$n10 stderr '${l%%|*}\\r<report line>' is neutralized on stderr and absent from stdout"
done
[ "$(fx_count_contract "$LE.split")" = "0" ]
fx_check $? "C10e. CR+LF split stderr carries no line the contract reader accepts"
# c10_exact <file> <line> — lines byte-equal to <line>; MSYS grep drops a trailing CR before matching,
# and Git Bash drops a $'\r' literal written inside $(...), so the CR lines are passed in variables.
c10_exact() {
    local n=0 x
    while IFS= read -r x || [ -n "$x" ]; do [ "$x" = "$2" ] && n=$((n + 1)); done <"$1"
    echo "$n"
}
C10_HELLO=$'hello\r'
C10_CRLF_LINE="[run-all:neutralized] $C10_CRLF_CONTRACT"$'\r'
[ "$(c10_exact "$LO" "$C10_HELLO")" = "1" ] && [ "$(c10_exact "$LO" 'hello')" = "0" ]
fx_check $? "C10f. control: an ordinary CRLF line 'hello\\r\\n' is replayed byte-for-byte, trailing CR kept"
[ "$(c10_exact "$LO" "$C10_CRLF_LINE")" = "1" ] &&
    [ "$(grep -c '^RUN_CONTRACT: PASS=55' "$LO.split")" = "0" ]
fx_check $? "C10g. control: a CRLF contract-shaped child line is prefixed, its trailing CR kept"
case_end

# --- several lone CRs: the forged segment sits after the second CR, or between two ----
# Codex round-5 C1. <printf format>|<forged segment>; the child prints <format>\n on its stream.
C10M_OUT=('prefix\rprogress\rRUN_CONTRACT: PASS=97 FAIL=0 SKIP=0 EXECUTED=97 UNRUNNABLE=0 TIMEOUT=0|RUN_CONTRACT: PASS=97 FAIL=0 SKIP=0 EXECUTED=97 UNRUNNABLE=0 TIMEOUT=0'
    'a\rb\rFAIL: forged-m-out.sh (exit 1)|FAIL: forged-m-out.sh (exit 1)'
    'a\rb\rPASS forged-m-out.sh::c target=t|PASS forged-m-out.sh::c target=t'
    'a\rRUN_CONTRACT: PASS=96 FAIL=0 SKIP=0 EXECUTED=96 UNRUNNABLE=0 TIMEOUT=0\rtail|RUN_CONTRACT: PASS=96 FAIL=0 SKIP=0 EXECUTED=96 UNRUNNABLE=0 TIMEOUT=0')
C10M_ERR=('prefix\rprogress\rRUN_CONTRACT: PASS=95 FAIL=0 SKIP=0 EXECUTED=95 UNRUNNABLE=0 TIMEOUT=0|RUN_CONTRACT: PASS=95 FAIL=0 SKIP=0 EXECUTED=95 UNRUNNABLE=0 TIMEOUT=0'
    'a\rb\rFAIL: forged-m-err.sh (exit 1)|FAIL: forged-m-err.sh (exit 1)'
    'a\rb\rPASS forged-m-err.sh::c target=t|PASS forged-m-err.sh::c target=t'
    'a\rRUN_CONTRACT: PASS=94 FAIL=0 SKIP=0 EXECUTED=94 UNRUNNABLE=0 TIMEOUT=0\rtail|RUN_CONTRACT: PASS=94 FAIL=0 SKIP=0 EXECUTED=94 UNRUNNABLE=0 TIMEOUT=0')
case_begin "multi-cr-child-line-cannot-forge-report-lines" "bin/lib/run-all-report.sh"
M="$(rr_new_root)" || { fx_fail "C10h fixture root could not be built"; fx_finish; }
c10m_body=()
for l in "${C10M_OUT[@]}"; do c10m_body+=("printf '${l%%|*}\\n'"); done
for l in "${C10M_ERR[@]}"; do c10m_body+=("printf '${l%%|*}\\n' >&2"); done
rr_add_raw "$M" c10-multi-cr "${c10m_body[@]}" 'exit 0'
MO="$FX_TMP_ROOT/multi-cr.out"
ME="$FX_TMP_ROOT/multi-cr.err"
rr_exec "$M" 90 "$MO" "$ME" -j 1 "$M/tests/bin/c10-multi-cr.sh"; MRC=$?
tr '\r' '\n' <"$MO" >"$MO.split"
tr '\r' '\n' <"$ME" >"$ME.split"
CTL_OUTS+=("$MO.split" "$ME.split")
[ "$MRC" -eq 0 ] && [ "$(rr_contract_rest "$MO")" = "${C10_CANON#RUN_CONTRACT: }" ]
fx_check $? "C10h. the run is one passing test: exit 0, canonical contract PASS=1 EXECUTED=1 (rc=$MRC)"
[ "$(grep -c '^RUN_CONTRACT:' "$MO.split")" = "1" ] && [ "$(fx_count_contract "$MO.split")" = "1" ] &&
    [ "$(grep '^RUN_CONTRACT:' "$MO.split")" = "$C10_CANON" ]
fx_check $? "C10i. CR+LF split stdout: exactly one segment begins with RUN_CONTRACT:, the canonical one (got $(grep -c '^RUN_CONTRACT:' "$MO.split"))"
# c10m_line <format> — the whole line rar_neutralize must print: prefix, then the child line with each CR as a space.
c10m_line() { printf -v C10M_WANT '%b' "$1"; C10M_WANT="[run-all:neutralized] ${C10M_WANT//$'\r'/ }"; }
n10=0
for l in "${C10M_OUT[@]}"; do
    n10=$((n10 + 1))
    c10m_line "${l%%|*}"
    c10_disarmed "$MO" "$MO.split" "${l#*|}" && [ "$(c10_exact "$MO" "$C10M_WANT")" = "1" ]
    fx_check $? "C10j.$n10 stdout multi-CR line is one prefixed line, no CR+LF segment is the forged line"
done
n10=0
for l in "${C10M_ERR[@]}"; do
    n10=$((n10 + 1))
    c10m_line "${l%%|*}"
    c10_disarmed "$ME" "$ME.split" "${l#*|}" && [ "$(c10_exact "$ME" "$C10M_WANT")" = "1" ] &&
        ! grep -qF -- "${l#*|}" "$MO"
    fx_check $? "C10k.$n10 stderr multi-CR line is one prefixed line on stderr and absent from stdout"
done
[ "$(fx_count_contract "$ME.split")" = "0" ] && [ "$(grep -c '^RUN_CONTRACT:' "$ME.split")" = "0" ]
fx_check $? "C10l. CR+LF split stderr carries no segment beginning with RUN_CONTRACT:"
! grep -qE '^(FAIL: |PASS )forged-m-' "$MO.split" "$ME.split"
fx_check $? "C10m. no CR+LF segment of either stream is a child-forged case or file-level FAIL line"
! grep -q $'\r' "$MO" && ! grep -q $'\r' "$ME"
fx_check $? "C10n. no raw CR survives in either stream (each multi-CR line was neutralized)"
case_end

# --- table-driven _rar_disp through rar_unit: control chars in name / target / script ----
# Codex round-4 C2. TAB is the cases.tsv separator, so it reaches a field only as the last
# field's interior (the target); LF cannot sit inside a line-based row, so it is covered in
# the script name. CR is stripped before display (CRLF rows), every other control becomes a space.
C11_TABLE="$(cat <<'EOF'
cr|PASS|a\rb|t\rx|ab|tx
soh-esc|PASS|c\x01d|t\x1bu|c d|t u
vt-ff|FAIL|e\vf|t\fv|e f|t v
c0-del|SKIP|m\x02\x7fn|z\x1fz|m  n|z z
cr-soh|XFAIL|g\r\x01h|t\r|g h|t
tab-in-target|XPASS|tabname|t1\tt2|tabname|t1 t2
ansi|PASS|\x1b[31mred\x1b[0m|o\x0bk| [31mred [0m|o k
EOF
)"
C11_S=$'tests/bin/c11\nRUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9 UNRUNNABLE=0 TIMEOUT=0\rFAIL: forged.sh (exit 1)\n.sh'
C11_SD='tests/bin/c11 RUN_CONTRACT: PASS=9 FAIL=0 SKIP=0 EXECUTED=9 UNRUNNABLE=0 TIMEOUT=0 FAIL: forged.sh (exit 1) .sh'
C11_DIR="$FX_TMP_ROOT/c11-res"
mkdir -p "$C11_DIR"
: >"$C11_DIR/cases.tsv"
C11_IDS=() C11_WANTS=()
seq11=0
while IFS='|' read -r id st nm tg wnm wtg; do
    [[ -z "$id" || "$id" =~ ^[[:space:]]*# ]] && continue
    seq11=$((seq11 + 1))
    printf -v nm '%b' "$nm"
    printf -v tg '%b' "$tg"
    printf '%s\t%s\t%s\t%s\n' "$seq11" "$st" "$nm" "$tg" >>"$C11_DIR/cases.tsv"
    C11_IDS+=("$id")
    C11_WANTS+=("$st $C11_SD::$wnm target=$wtg")
done <<<"$C11_TABLE"
C11_OUT="$FX_TMP_ROOT/c11.out"
(. "$FX_REPO_ROOT/bin/lib/run-all-report.sh" && rar_unit "$C11_S" "$C11_DIR" 0 PASS) >"$C11_OUT" 2>&1
C11_RC=$?
cat -v "$C11_OUT" >"$C11_OUT.v" 2>/dev/null
CTL_OUTS+=("$C11_OUT.v")
case_begin "rar-disp-control-chars-table" "bin/lib/run-all-report.sh"
c11_cr=0
while IFS= read -r x || [ -n "$x" ]; do [[ "$x" == *$'\r'* ]] && c11_cr=$((c11_cr + 1)); done <"$C11_DIR/cases.tsv"
[ "$C11_RC" -eq 0 ] && [ "$seq11" -eq 7 ] && [ "$c11_cr" -eq 2 ]
fx_check $? "C11. rar_unit returns 0 over a 7-row table whose rows hold raw CRs (rc=$C11_RC rows=$seq11 cr-rows=$c11_cr)"
for ((i = 0; i < ${#C11_IDS[@]}; i++)); do
    got="$(grep -cxF -- "${C11_WANTS[i]}" "$C11_OUT")"
    if [ "$got" = "1" ]; then
        fx_pass "C11.${C11_IDS[i]} exactly one case line, controls shown as spaces"
    else
        fx_fail "C11.${C11_IDS[i]} want=$(printf '%q' "${C11_WANTS[i]}") matches=$got"
    fi
done
c11_want="$(printf '%s\n' "PASS: $C11_SD" "${C11_WANTS[@]}")"
[ "$(cat "$C11_OUT")" = "$c11_want" ] && [ "$(grep -c '' "$C11_OUT")" = "$((1 + seq11))" ]
fx_check $? "C11b. output is the file-level line then one line per case in seq order, none missing or merged"
c11_ctl=0
while IFS= read -r x || [ -n "$x" ]; do [[ "$x" == *[[:cntrl:]]* ]] && c11_ctl=$((c11_ctl + 1)); done <"$C11_OUT"
[ "$c11_ctl" -eq 0 ]
fx_check $? "C11c. no raw control character besides the line feed reaches the output"
[ "$(grep -c '^[[:blank:]]*RUN_CONTRACT:' "$C11_OUT")" = "0" ] && [ "$(grep -c '^FAIL: forged' "$C11_OUT")" = "0" ]
fx_check $? "C11d. no output line begins with a contract or a forged file-level FAIL"
case_end

[ "$FX_ERRORS" -eq 0 ] || {
    fx_show_tail "$NO" 20; fx_show_tail "$SO" 20; fx_show_tail "$AO" 20
    for f in ${CTL_OUTS[@]+"${CTL_OUTS[@]}"}; do fx_show_tail "$f" 20; done
}
fx_finish
