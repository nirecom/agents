#!/usr/bin/env bash
# Tests: tests/lib/harness.sh, tests/lib/xfail.sh
# Tags: tests, harness, xfail, run-all, scope:issue-specific
# #2501: the bash harness writes per-case records to <RUN_ALL_RESULT_DIR>/cases.tsv
# (`<seq>\t<STATE>\t<case>\t<target>`) only when RUN_ALL_RESULT_OWNER equals its own $0,
# and unsets both env vars on source. Fixtures are real scripts that source the worktree
# harness; each is launched as `bash <path>` so $0 is exactly the owner string.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD/iso"
FXD="$TMPD/fx"
mkdir -p "$FXD"
T=$'\t'

# fx_write <name> — fixture script from stdin, behind a preamble sourcing the worktree libs. Sets FXF.
fx_write() {
    FXF="$FXD/$1.sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf '. %q/tests/lib/harness.sh\n' "$SCRIPT_CHECKOUT_ROOT"
        printf '. %q/tests/lib/xfail.sh\n' "$SCRIPT_CHECKOUT_ROOT"
        cat
    } >"$FXF"
}

# fx_run <name> [owner] — runs $FXF with the result env; owner defaults to $FXF. Sets RD/FXOUT/FXRC.
fx_run() {
    RD="$FXD/$1.rd"
    mkdir -p "$RD"
    FXOUT="$(cd "$FXD" && run_with_timeout 30 env "RUN_ALL_RESULT_DIR=$(np "$RD")" \
        "RUN_ALL_RESULT_OWNER=${2:-$FXF}" bash "$FXF" 2>&1)"
    FXRC=$?
}

# final_state <seq> — STATE of the last record for <seq> in $RD/cases.tsv ("(none)" if absent).
final_state() {
    local s
    s="$(awk -F'\t' -v q="$1" '$1 == q { st = $2 } END { print st }' "$RD/cases.tsv" 2>/dev/null)"
    printf '%s' "${s:-(none)}"
}

# expect_file <label> <want> — $RD/cases.tsv equals <want> byte for byte.
expect_file() {
    local got
    got="$(cat "$RD/cases.tsv" 2>/dev/null || printf '(no cases.tsv)')"
    if [ "$got" = "$2" ]; then
        pass "$1"
    else
        fail "$1" "want=<<${2//$'\n'/|}>> got=<<${got//$'\n'/|}>> fixture-out=<<$(printf '%s' "$FXOUT" | tail -n 3 | tr '\n' '|')>>"
    fi
}

case_begin "state-priority" "tests/lib/harness.sh"
fx_write priority <<'FX'
case_begin "c-fail" "tests/lib/harness.sh"
pass "p"
fail "f"
case_end
case_begin "c-xpass" "tests/lib/xfail.sh"
xfail_eq "gap closed" "a" "a"
case_end
case_begin "c-xfail" "tests/lib/xfail.sh"
xfail_eq "gap open" "a" "b"
case_end
case_begin "c-pass" "tests/lib/harness.sh"
pass "p"
skip "s"
case_end
case_begin "c-skip" "tests/lib/harness.sh"
skip "s"
case_end
exit 0
FX
fx_run priority
assert_eq "$(final_state 1)" "FAIL"
assert_eq "$(final_state 2)" "XPASS"
assert_eq "$(final_state 3)" "XFAIL"
assert_eq "$(final_state 4)" "PASS"
assert_eq "$(final_state 5)" "SKIP"
case_end

case_begin "unobserved-when-no-counter-moves" "tests/lib/harness.sh"
fx_write unobserved <<'FX'
case_begin "c-echo-only" "tests/lib/harness.sh"
echo "PASS: printed but not counted"
case_end
exit 0
FX
fx_run unobserved
assert_eq "$(final_state 1)" "UNOBSERVED"
case_end

case_begin "open-record-then-final-same-seq-and-implicit-close" "tests/lib/harness.sh"
fx_write implicit <<'FX'
case_begin "c-a" "tests/lib/harness.sh"
pass "a"
case_begin "c-b" "tests/lib/xfail.sh"
fail "b"
case_end
exit 0
FX
fx_run implicit
expect_file "OPEN at begin, final record on the same seq, next begin closes the open case" \
    "1${T}OPEN${T}c-a${T}tests/lib/harness.sh
1${T}PASS${T}c-a${T}tests/lib/harness.sh
2${T}OPEN${T}c-b${T}tests/lib/xfail.sh
2${T}FAIL${T}c-b${T}tests/lib/xfail.sh"
case_end

case_begin "unclosed-case-stays-open" "tests/lib/harness.sh"
fx_write unclosed <<'FX'
case_begin "c-left-open" "tests/lib/harness.sh"
pass "a"
exit 0
FX
fx_run unclosed
expect_file "a case never closed before exit leaves only its OPEN record" \
    "1${T}OPEN${T}c-left-open${T}tests/lib/harness.sh"
case_end

case_begin "owner-mismatch-writes-nothing" "tests/lib/harness.sh"
fx_write owner <<'FX'
case_begin "c-owned" "tests/lib/harness.sh"
pass "a"
case_end
exit 0
FX
# Control: the matching owner writes, so the mismatch run below is not trivially silent.
fx_run owner-match
assert_eq "$(final_state 1)" "PASS"
fx_run owner-mismatch "$FXF.someone-else"
if [ -z "$(ls -A "$RD" 2>/dev/null)" ] && printf '%s\n' "$FXOUT" | grep -q '^PASS: a$'; then
    pass "owner != \$0: the fixture ran (PASS: a) and its result dir stays empty"
else
    fail "owner-mismatch" "result dir: <<$(ls -A "$RD" 2>/dev/null | tr '\n' ' ')>> out=<<$(printf '%s' "$FXOUT" | tr '\n' '|')>>"
fi
case_end

case_begin "env-unset-after-source" "tests/lib/harness.sh"
fx_write envunset <<'FX'
echo "self=${RUN_ALL_RESULT_DIR-unset}|${RUN_ALL_RESULT_OWNER-unset}"
bash -c 'echo "child=${RUN_ALL_RESULT_DIR-unset}|${RUN_ALL_RESULT_OWNER-unset}"'
exit 0
FX
for mode in match mismatch; do
    if [ "$mode" = "match" ]; then fx_run envunset-match; else fx_run envunset-mismatch "$FXF.other"; fi
    if printf '%s\n' "$FXOUT" | grep -qxF 'self=unset|unset' && printf '%s\n' "$FXOUT" | grep -qxF 'child=unset|unset'; then
        pass "owner $mode: both result env vars are unset in the test and its child after sourcing"
    else
        fail "env-unset/$mode" "out=<<$(printf '%s' "$FXOUT" | tr '\n' '|')>>"
    fi
done
case_end

case_begin "no-env-writes-nothing-and-harness-works" "tests/lib/harness.sh"
fx_write noenv <<'FX'
case_begin "c-plain" "tests/lib/harness.sh"
pass "a"
case_end
echo "counts=$PASS/$FAIL"
exit 0
FX
mkdir -p "$FXD/noenv-cwd"
NOENV_OUT="$(cd "$FXD/noenv-cwd" && run_with_timeout 30 env -u RUN_ALL_RESULT_DIR -u RUN_ALL_RESULT_OWNER bash "$FXF" 2>&1)"
NOENV_RC=$?
if [ "$NOENV_RC" = "0" ] && printf '%s\n' "$NOENV_OUT" | grep -qxF 'counts=1/0' \
    && [ -z "$(find "$FXD" -name cases.tsv -path '*noenv*' -print)" ]; then
    pass "no result env: the harness counts normally (1/0, rc 0) and writes no cases.tsv"
else
    fail "no-env" "rc=$NOENV_RC out=<<$(printf '%s' "$NOENV_OUT" | tr '\n' '|')>>"
fi
case_end

case_begin "xpass-counter" "tests/lib/xfail.sh"
fx_write xpassn <<'FX'
echo "start=${XPASS_N-undefined}"
xfail_eq "met" "a" "a"
echo "after=${XPASS_N-undefined} fail=$FAIL"
exit 0
FX
fx_run xpassn
if printf '%s\n' "$FXOUT" | grep -qxF 'start=0' && printf '%s\n' "$FXOUT" | grep -qxF 'after=1 fail=1'; then
    pass "XPASS_N starts at 0 on source and an XPASS increments it while FAIL still rises"
else
    fail "xpass-counter" "out=<<$(printf '%s' "$FXOUT" | tr '\n' '|')>>"
fi
case_end

case_begin "case-name-tab-newline-sanitized" "tests/lib/harness.sh"
fx_write sanitize <<'FX'
case_begin $'c\tweird\nname' "tests/lib/harness.sh"
pass "a"
case_end
exit 0
FX
fx_run sanitize
expect_file "tab and newline in the case name become spaces in both records" \
    "1${T}OPEN${T}c weird name${T}tests/lib/harness.sh
1${T}PASS${T}c weird name${T}tests/lib/harness.sh"
case_end

# --- harness_discard_pass: a dry pass leaves no record and no case-state trace -----------------
case_begin "discard-fail-in-open-case" "tests/lib/harness.sh"
fx_write discard-open <<'FX'
case_begin "c-open" "tests/lib/harness.sh"
pass "before"
dry() { fail "dry fail"; }
harness_discard_pass dry
echo "after-dry fail=$FAIL failed=[${_HARNESS_CASE_FAILED:-}] open=[${_HARNESS_CASE_OPEN:-}]"
fail "real fail"
case_end
exit 0
FX
fx_run discard-open
expect_file "H1. a dry fail writes nothing; the later real fail writes the case's one FAIL record" \
    "1${T}OPEN${T}c-open${T}tests/lib/harness.sh
1${T}FAIL${T}c-open${T}tests/lib/harness.sh"
if printf '%s\n' "$FXOUT" | grep -qxF 'after-dry fail=0 failed=[] open=[1]'; then
    pass "H1. FAIL and _HARNESS_CASE_FAILED are restored and the case stays open"
else
    fail "H1-state" "out=<<$(printf '%s' "$FXOUT" | tr '\n' '|')>>"
fi
case_end

case_begin "discard-cases-inside-open-case" "tests/lib/harness.sh"
fx_write discard-cases <<'FX'
case_begin "c-outer" "tests/lib/harness.sh"
dry() {
    case_begin "d1" "tests/run-all.sh"; pass "x"; case_end
    case_begin "d2" "tests/run-all.sh"; fail "y"; skip "z"
}
harness_discard_pass dry
echo "state seq=$_HARNESS_CASE_SEQ open=$_HARNESS_CASE_OPEN name=$_HARNESS_CASE_NAME target=$_HARNESS_CASE_TARGET cur=$CURRENT_CASE/$CURRENT_CASE_TARGET counts=$PASS/$FAIL/$SKIP"
pass "outer"
case_end
exit 0
FX
fx_run discard-cases
expect_file "H2. cases begun and ended inside a dry pass write no record; the outer case closes PASS" \
    "1${T}OPEN${T}c-outer${T}tests/lib/harness.sh
1${T}PASS${T}c-outer${T}tests/lib/harness.sh"
if printf '%s\n' "$FXOUT" | grep -qxF 'state seq=1 open=1 name=c-outer target=tests/lib/harness.sh cur=c-outer/tests/lib/harness.sh counts=0/0/0'; then
    pass "H2. seq, the open case's name/target, CURRENT_CASE* and the counters are restored"
else
    fail "H2-state" "out=<<$(printf '%s' "$FXOUT" | tr '\n' '|')>>"
fi
case_end

case_begin "real-pass-after-discard-records-normally" "tests/lib/harness.sh"
fx_write discard-seq <<'FX'
case_begin "c-a" "tests/lib/harness.sh"
pass "a"
case_end
dry() { case_begin "d" "tests/run-all.sh"; fail "z"; case_end; }
harness_discard_pass dry
case_begin "c-b" "tests/lib/xfail.sh"
pass "b"
case_end
exit 0
FX
fx_run discard-seq
expect_file "H3. records before and after a dry pass carry consecutive seq numbers, no gap or duplicate" \
    "1${T}OPEN${T}c-a${T}tests/lib/harness.sh
1${T}PASS${T}c-a${T}tests/lib/harness.sh
2${T}OPEN${T}c-b${T}tests/lib/xfail.sh
2${T}PASS${T}c-b${T}tests/lib/xfail.sh"
case_end

case_begin "discard-no-result-dir-nested-stdin-rc" "tests/lib/harness.sh"
fx_write discard-edge <<'FX'
set -euo pipefail
case_begin "c-n" "tests/lib/harness.sh"
pass "kept"
rows() { local l n=0; while IFS= read -r l; do n=$((n + 1)); fail "row $l"; done; echo "$n" >"$0.seen"; return 3; }
inner() { fail "inner"; xfail_eq "gap" "a" "b"; case_begin "di" "tests/run-all.sh"; }
outer() {
    fail "outer"
    harness_discard_pass inner
    echo "mid fail=$FAIL xfail=$XFAIL_N seq=$_HARNESS_CASE_SEQ name=$_HARNESS_CASE_NAME" >"$0.mid"
    case_begin "do" "tests/run-all.sh"
    return 1
}
printf 'r1\nr2\n' >"$0.tbl"
harness_discard_pass rows <"$0.tbl"
harness_discard_pass outer
echo "end pass=$PASS fail=$FAIL skip=$SKIP xfail=$XFAIL_N xpass=$XPASS_N seq=$_HARNESS_CASE_SEQ name=$_HARNESS_CASE_NAME"
case_end
exit 0
FX
mkdir -p "$FXD/edge-cwd"
EDGE_OUT="$(cd "$FXD/edge-cwd" && run_with_timeout 30 env -u RUN_ALL_RESULT_DIR -u RUN_ALL_RESULT_OWNER bash "$FXF" 2>&1)"
EDGE_RC=$?
if [ "$EDGE_RC" = "0" ] && printf '%s\n' "$EDGE_OUT" | grep -qxF 'end pass=1 fail=0 skip=0 xfail=0 xpass=0 seq=1 name=c-n' \
    && [ -z "$(find "$FXD" -name cases.tsv -path '*edge*' -print)" ]; then
    pass "H4. no result dir: dry passes (stdin-fed, nested, non-zero rc under set -e) restore every counter, write no cases.tsv"
else
    fail "H4-no-result-dir" "rc=$EDGE_RC out=<<$(printf '%s' "$EDGE_OUT" | tr '\n' '|')>>"
fi
assert_eq "H4. the stdin-fed dry pass read the caller's table: $(cat "$FXF.seen" 2>/dev/null)" "H4. the stdin-fed dry pass read the caller's table: 2"
assert_eq "$(cat "$FXF.mid" 2>/dev/null)" "mid fail=1 xfail=0 seq=1 name=c-n"
case_end

# H5 end to end: the rtk_batched shape (a prefetch pass that fails, then the real pass) through the runner.
# shellcheck source=feature-2501-run-all-report/_fx.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/tests/feature-2501-run-all-report/_fx.sh"
FX_TMP_ROOT="$TMPD/fxroot"
FX_CACHE_DIR="$FX_TMP_ROOT/run-all-cache"
mkdir -p "$FX_CACHE_DIR"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
unset RUN_ALL_REPORT_LIB RUN_ALL_LAUNCH_LIB RUN_ALL_TIMEOUT_SECONDS 2>/dev/null || true
fx_drop_ambient_controls

# h5_add <root> <id> <real-ok 1|0> <dry-call> — a prefetch/real fixture; <dry-call> runs the dry pass.
h5_add() {
    rr_add_harness "$1" "$2" <<FX
REAL_OK=$3
PREFETCH=0
probe() { if [ "\$PREFETCH" = 1 ] || [ "\$REAL_OK" != 1 ]; then fail "probe"; else pass "probe"; fi; }
unit_cases() {
    case_begin "u1" "tests/lib/harness.sh"; probe; case_end
    case_begin "u2" "tests/lib/harness.sh"; probe; case_end
}
handrolled() { local p="\$PASS" f="\$FAIL" s="\$SKIP"; "\$@" >/dev/null 2>&1 || true; PASS="\$p"; FAIL="\$f"; SKIP="\$s"; }
PREFETCH=1; $4 unit_cases; PREFETCH=0
unit_cases
echo "Results: PASS=\$PASS FAIL=\$FAIL"
[ "\$FAIL" -eq 0 ]
FX
}

H5R="$(rr_new_root)" || fail "H5 fixture root could not be built"
h5_add "$H5R" h5-ok 1 harness_discard_pass
h5_add "$H5R" h5-bad 0 harness_discard_pass
h5_add "$H5R" h5-handrolled 1 handrolled
# h5_run <tag> <id> — the fixture runner on one file; rc in H5_RC, stdout at $FX_TMP_ROOT/<tag>.out.
h5_run() {
    H5_RC=0
    rr_exec "$H5R" 120 "$FX_TMP_ROOT/$1.out" "$FX_TMP_ROOT/$1.err" -j 1 "$H5R/tests/bin/$2.sh" || H5_RC=$?
}

case_begin "discard-pass-end-to-end-through-run-all" "tests/lib/harness.sh"
h5_run ok h5-ok
H5O="$FX_TMP_ROOT/ok.out"
assert_eq "H5. ok: rc=$H5_RC contract=$(rr_contract_rest "$H5O")" "H5. ok: rc=0 contract=PASS=1 FAIL=0 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0"
if grep -qE '^PASS .*h5-ok\.sh::u1 target=tests/lib/harness\.sh$' "$H5O" && grep -qE '^PASS .*h5-ok\.sh::u2 target=tests/lib/harness\.sh$' "$H5O" \
    && ! grep -qE '^[A-Z]+ .*h5-ok\.sh::\(file\)' "$H5O" && ! grep -qE '^FAIL .*h5-ok\.sh' "$H5O"; then
    pass "H5. ok: per-case lines u1/u2 are PASS only"
else
    fail "H5-ok-cases" "$(grep -E 'h5-ok' "$H5O" | fx_mask | tr '\n' '|')"
fi
h5_run bad h5-bad
H5B="$FX_TMP_ROOT/bad.out"
assert_eq "H5. control bad: rc=$H5_RC contract=$(rr_contract_rest "$H5B")" "H5. control bad: rc=1 contract=PASS=0 FAIL=1 SKIP=0 EXECUTED=1 UNRUNNABLE=0 TIMEOUT=0"
if grep -qE '^FAIL .*h5-bad\.sh::u1 target=tests/lib/harness\.sh$' "$H5B" && grep -qE '^FAIL .*h5-bad\.sh::u2 target=tests/lib/harness\.sh$' "$H5B"; then
    pass "H5. control bad: a failing real pass still reports FAIL per case"
else
    fail "H5-bad-cases" "$(grep -E 'h5-bad' "$H5B" | fx_mask | tr '\n' '|')"
fi
# Non-vacuity: the hand-rolled counter restore (the pre-primitive shape) leaks its dry FAIL records.
h5_run hand h5-handrolled
assert_eq "H5. control hand-rolled restore: rc=$H5_RC" "H5. control hand-rolled restore: rc=1"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
