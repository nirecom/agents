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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
