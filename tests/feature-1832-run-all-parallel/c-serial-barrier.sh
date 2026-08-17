#!/usr/bin/env bash
# c-serial-barrier.sh — the serial lane runs a declared test alone.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, scope:issue-specific

# WHY: `# Serial: <reason>` grabs a shared resource — the scheduler drains all in-flight
# jobs, runs it alone, then resumes; the barrier is announced on stderr so a stall names its owner.

# WHY interval test, not window scan: a job that started before and ended after the serial
# test leaves no event inside the window, so a no-barrier scheduler looks compliant; overlap is checked over active intervals instead.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "c-serial-barrier"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export CLAUDE_WORKFLOW_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true

# serial_violations <log> <serial-id> — ordinary job ids whose active interval overlaps the
# serial test's (empty = respected); unterminated jobs are treated as still running so a mid-flight kill can't hide.
serial_violations() {
    awk -v sid="$2" '
        $1 == "start" { if (!($2 in s)) s[$2] = NR }
        $1 == "end"   { e[$2] = NR }
        END {
            inf = NR + 1
            if (!(sid in s)) exit
            ss = s[sid]; se = (sid in e) ? e[sid] : inf
            for (id in s) {
                if (id == sid) continue
                js = s[id]; je = (id in e) ? e[id] : inf
                if (js < se && ss < je) print id
            }
        }' "$1" 2>/dev/null | sort | tr '\n' ' ' | sed 's/[[:blank:]]*$//'
}

# legacy_window_scan <log> <serial-id> — the discarded point-in-window form,
# kept ONLY as the counter-proof's control: it is what the rewrite replaces.
legacy_window_scan() {
    local sl el
    sl="$(grep -n "^start $2\$" "$1" | head -n 1 | cut -d: -f1)"
    el="$(grep -n "^end $2\$" "$1" | head -n 1 | cut -d: -f1)"
    [ -n "$sl" ] && [ -n "$el" ] || return 0
    sed -n "$((sl + 1)),$((el - 1))p" "$1" | awk '{ print $2 }' \
        | grep -v "^$2\$" | sort -u | tr '\n' ' ' | sed 's/[[:blank:]]*$//'
}

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then fx_pass "$name -> [$got]"
    else fx_fail "$name -> want=[$want] got=[$got]"; fi
}

# ==========================================================================
# C0. Counter-proof: checker verdicts on synthetic logs with known-by-construction answers. `;` separates log lines per row.
# ==========================================================================
SID="srl"
while IFS='|' read -r name body want; do
    case "$name" in ''|\#*) continue ;; esac
    name="$(printf '%s' "$name" | tr -d '[:blank:]')"
    want="$(printf '%s' "$want" | sed 's/^[[:blank:]]*//; s/[[:blank:]]*$//')"
    [ "$want" = "-" ] && want=""
    synth="$FX_TMP_ROOT/synth-$name.log"
    printf '%s' "$body" | tr ';' '\n' | sed 's/^[[:blank:]]*//; s/[[:blank:]]*$//; /^$/d' > "$synth"
    assert_eq "C0/$name" "$want" "$(serial_violations "$synth" "$SID")"
done <<'TABLE'
respected      | start a; end a; start srl; end srl; start b; end b        | -
span-contains  | start a; start srl; end srl; end a                        | a
overlap-head   | start a; start srl; end a; end srl                        | a
overlap-tail   | start srl; start a; end srl; end a                        | a
nested-inside  | start srl; start a; end a; end srl                        | a
never-ends     | start a; start srl; end srl                               | a
two-spanners   | start a; start b; start srl; end srl; end b; end a        | a b
serial-absent  | start a; end a                                            | -
TABLE

# span-contains is the case the rewrite exists for: the legacy scan is silent while the interval
# checker names the offender — asserting both sides is what makes this a counter-proof.
SPAN="$FX_TMP_ROOT/synth-span-contains.log"
assert_eq "C0/legacy-is-blind-to-span" "" "$(legacy_window_scan "$SPAN" "$SID")"
assert_eq "C0/rewrite-catches-span" "a" "$(serial_violations "$SPAN" "$SID")"

# ==========================================================================
# C1-C3. Six dummies, one of them serial, at -j 8.
# ==========================================================================
SERIAL_ID="t4-serial"
ROOT="$(fx_new_root)"
fx_add_dummy "$ROOT" t1 --sleep 2 --lines 1 --log
fx_add_dummy "$ROOT" t2 --sleep 2 --lines 1 --log
fx_add_dummy "$ROOT" t3 --sleep 2 --lines 1 --log
fx_add_dummy "$ROOT" "$SERIAL_ID" --sleep 1 --lines 1 --err-lines 1 --log \
    --serial "fixture: exclusive access to the shared overlap log"
fx_add_dummy "$ROOT" t5 --sleep 2 --lines 1 --log
fx_add_dummy "$ROOT" t6 --sleep 2 --lines 1 --log

OUT="$FX_TMP_ROOT/serial.out"
ERR="$FX_TMP_ROOT/serial.err"
LOG="$(fx_log "$ROOT")"

# The whole case is bounded: 6 dummies, 2s each, 8 slots.
fx_exec "$ROOT" 90 "$OUT" "$ERR" -j 8 --all
RC=$?

EXECUTED="$(fx_contract_field "$OUT" EXECUTED)"
[ "$EXECUTED" = "6" ]
fx_check $? "C1. -j 8: all 6 dummies ran (EXECUTED=$EXECUTED, exit $RC)"

# --- the barrier itself ---------------------------------------------------
if [ ! -f "$LOG" ]; then
    fx_fail "C2. shared overlap log was never written — no dummy ran under -j 8 (serial lane unverifiable)"
elif ! grep -q "^start $SERIAL_ID\$" "$LOG" || ! grep -q "^end $SERIAL_ID\$" "$LOG"; then
    fx_fail "C2. the serial dummy did not record start and end in the shared log (EXECUTED=$EXECUTED)"
else
    V="$(serial_violations "$LOG" "$SERIAL_ID")"
    if [ -z "$V" ] && [ "$EXECUTED" = "6" ]; then
        fx_pass "C2. -j 8, EXECUTED=6: no ordinary job's active interval overlaps the serial test's"
    else
        fx_fail "C2. want EXECUTED=6 and zero interval overlap with the serial test, got EXECUTED=$EXECUTED overlapping=[$V]"
    fi
fi

# --- the two stderr announcements -----------------------------------------
BARRIER_N="$(grep -n "^\[run-all\] serial barrier: draining [0-9]* job(s) before .*$SERIAL_ID\.sh\$" "$ERR" | head -n 1 | cut -d: -f1)"
ALONE_N="$(grep -n "^\[run-all\] serial: running .*$SERIAL_ID\.sh alone\$" "$ERR" | head -n 1 | cut -d: -f1)"
OWN_N="$(grep -n "$SERIAL_ID err line 1\$" "$ERR" | head -n 1 | cut -d: -f1)"

[ -n "$BARRIER_N" ]
fx_check $? "C3a. stderr announces the barrier: '[run-all] serial barrier: draining N job(s) before <script>'"
[ -n "$ALONE_N" ]
fx_check $? "C3b. stderr announces the exclusive run: '[run-all] serial: running <script> alone'"

if [ -n "$BARRIER_N" ] && [ -n "$ALONE_N" ] && [ -n "$OWN_N" ] \
    && [ "$BARRIER_N" -lt "$ALONE_N" ] && [ "$ALONE_N" -lt "$OWN_N" ]; then
    fx_pass "C3c. both barrier lines precede the serial test's own stderr output"
else
    fx_fail "C3c. want barrier < running-alone < serial test's own stderr, got ${BARRIER_N:-none} / ${ALONE_N:-none} / ${OWN_N:-none}"
fi

# ==========================================================================
# C4. Spanning fixture (glob order a-long/b-mid/s-serial/z-tail): a no-barrier scheduler is
# still running the 10s a-long when the 1s s-serial starts and ends — exactly what the window scan couldn't see.
# ==========================================================================
SERIAL2_ID="s-serial"
SPAN_ROOT="$(fx_new_root)"
fx_add_dummy "$SPAN_ROOT" a-long --sleep 10 --lines 1 --log
fx_add_dummy "$SPAN_ROOT" b-mid  --sleep 2  --lines 1 --log
fx_add_dummy "$SPAN_ROOT" "$SERIAL2_ID" --sleep 1 --lines 1 --log \
    --serial "fixture: must not overlap the long-running job"
fx_add_dummy "$SPAN_ROOT" z-tail --sleep 2 --lines 1 --log

S_OUT="$FX_TMP_ROOT/span.out"
S_ERR="$FX_TMP_ROOT/span.err"
S_LOG="$(fx_log "$SPAN_ROOT")"
fx_exec "$SPAN_ROOT" 90 "$S_OUT" "$S_ERR" -j 4 --all
S_RC=$?
S_EXEC="$(fx_contract_field "$S_OUT" EXECUTED)"

if [ ! -f "$S_LOG" ] || ! grep -q "^end $SERIAL2_ID\$" "$S_LOG"; then
    fx_fail "C4. the serial dummy never completed in the spanning fixture (EXECUTED=${S_EXEC:-none}, exit $S_RC) — barrier unverifiable"
else
    SV="$(serial_violations "$S_LOG" "$SERIAL2_ID")"
    if [ -z "$SV" ] && [ "$S_EXEC" = "4" ]; then
        fx_pass "C4. -j 4, EXECUTED=4: the 10s job was drained before the serial test, not spanned across it"
    else
        fx_fail "C4. want EXECUTED=4 and no job spanning the serial test, got EXECUTED=${S_EXEC:-none} overlapping=[$SV]"
    fi
fi

[ "$FX_ERRORS" -eq 0 ] || fx_show_tail "$ERR" 20

fx_finish
