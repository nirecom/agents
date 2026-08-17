#!/usr/bin/env bash
# j-signal-cleanup.sh — Ctrl-C leaves nothing behind, and costs nothing when it never happens.
# Tests: tests/run-all.sh, bin/calibrate-test-parallelism.sh, bin/lib/run-all-parallelism.sh, bin/worker-dispatch/workers/test-runner.js
# Tags: tests, bin, parallel, scope:issue-specific

# WHY (CPR-WPH): sequentially there was at most one child to orphan; at -j N an
# interrupt can strand N children plus whatever they spawned, and those keep
# holding the CPU the developer just tried to free. So cleanup must be bounded
# (signal, one grace second, unconditional KILL — never an unbounded `wait`) and
# must not tax the ordinary path: a normal run may not pay the grace second.

# SIGINT is the signal the feature is NAMED for — Ctrl-C — and it is not a
# synonym for SIGTERM: a shell delivers it to the whole foreground group, a
# `kill -INT <pid>` reaches only the runner, and a trap handler written for one
# is routinely missing for the other. Both are therefore exercised against both
# reapers, so no teardown path is covered by inference.

# CPR-UNV: a surviving grandchild is a leak on EVERY host. The job-control probe
# below selects WHICH teardown path is under test — `kill -- -PGID` where job
# control exists, an explicit descendant walk where it does not — and is never
# allowed to downgrade a survivor to a note. A test that excuses orphans on the
# host that most needs the descendant walk would never fail where it matters.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "j-signal-cleanup"

kill -0 "$$" 2>/dev/null || { echo "SKIP: kill -0 is unavailable on this host"; exit 77; }

PGROUP_KILL="$(bash -c 'set -m 2>/dev/null; case $- in *m*) echo 1 ;; *) echo 0 ;; esac' 2>/dev/null || echo 0)"
if [ "$PGROUP_KILL" = "1" ]; then
    fx_note "job control available: the process-group teardown path is under test"
else
    fx_note "job control UNAVAILABLE: the explicit descendant-walk teardown path is under test"
fi

wait_started() {            # wait_started <path> <timeout-secs>
    local f="$1" t="$2" waited=0
    while [ "$waited" -lt "$t" ]; do
        [ -e "$f" ] && return 0
        fx_pid_alive "$FX_BG_PID" || return 1
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

pids_of() {                 # pids_of <root> <suffix>
    local f
    for f in "$1"/pids/*."$2"; do
        [ -f "$f" ] && cat "$f"
    done 2>/dev/null
    return 0
}

# --- (a) INT and TERM both tear down children AND grandchildren -------------
signal_case() {             # signal_case <reap-mode> <TERM|INT>
    local mode="$1" sig="$2" tag="$1-$2"
    local root children grandchildren
    root="$(fx_new_root)"
    fx_add_dummy "$root" k1 --sleep 60 --grandchild
    fx_add_dummy "$root" k2 --sleep 60 --grandchild
    fx_add_dummy "$root" k3 --sleep 60

    RUN_ALL_REAP="$mode" fx_exec_bg "$root" "$FX_TMP_ROOT/$tag.out" "$FX_TMP_ROOT/$tag.err" -j 4 --all
    if ! wait_started "$root/pids/k3.self" 12; then
        kill -KILL "$FX_BG_PID" 2>/dev/null || true
        fx_fail "J-$tag-x. the runner never started 3 parallel children under -j 4, so SIG$sig teardown is unverifiable"
        fx_fail "J-$tag-a. child teardown unverifiable for the same reason"
        fx_fail "J-$tag-b. descendant teardown unverifiable for the same reason"
        return 0
    fi

    children="$(pids_of "$root" self)"
    grandchildren="$(pids_of "$root" grandchild)"

    kill -"$sig" "$FX_BG_PID" 2>/dev/null || true
    if fx_wait_gone 15 "$FX_BG_PID"; then
        fx_pass "J-$tag-x. SIG$sig under $mode: the runner itself is gone within 15s (teardown is bounded)"
    else
        kill -KILL "$FX_BG_PID" 2>/dev/null || true
        fx_fail "J-$tag-x. the runner was still alive 15s after SIG$sig (cleanup_all is not bounded)"
    fi
    wait "$FX_BG_PID" 2>/dev/null || true

    if [ -n "$children" ] && fx_wait_gone 10 $children; then
        fx_pass "J-$tag-a. SIG$sig under $mode: every in-flight child test is gone within 10s"
    else
        fx_fail "J-$tag-a. SIG$sig under $mode: in-flight child tests survived 10s (pids: $(echo $children | tr '\n' ' '))"
    fi

    if [ -z "$grandchildren" ]; then
        fx_fail "J-$tag-b. no grandchild pid was recorded, so descendant teardown is unverifiable"
    elif fx_wait_gone 10 $grandchildren; then
        fx_pass "J-$tag-b. SIG$sig under $mode: processes the tests themselves spawned are gone within 10s"
    else
        fx_fail "J-$tag-b. SIG$sig under $mode: grandchildren survived 10s (pids: $(echo $grandchildren | tr '\n' ' ')) — with job control=$PGROUP_KILL the runner must reap descendants either by process group or by an explicit descendant walk"
    fi
}

for reap in waitn fifo; do
    for signal in TERM INT; do
        signal_case "$reap" "$signal"
    done
done

# --- (b) a child that ignores the signal is still killed, and 130 reported --

# 130 is the runner's single interrupted-exit code for BOTH signals: the caller
# distinguishes "the suite was cut short" from "the suite failed", never which
# signal did the cutting.

stub_case() {               # stub_case <TERM|INT>
    local sig="$1" opt="" kids grand rc=""
    case "$sig" in
        TERM) opt="--ignore-term" ;;
        INT)  opt="--ignore-int" ;;
    esac
    local root; root="$(fx_new_root)"
    fx_add_dummy "$root" s1 $opt --grandchild
    fx_add_dummy "$root" s2 --sleep 60

    fx_exec_bg "$root" "$FX_TMP_ROOT/stub-$sig.out" "$FX_TMP_ROOT/stub-$sig.err" -j 4 --all
    if ! wait_started "$root/pids/s1.self" 12; then
        kill -KILL "$FX_BG_PID" 2>/dev/null || true
        fx_fail "J-b1-$sig. the SIG$sig-ignoring dummy never started under -j 4, so the KILL escalation is unverifiable"
        fx_fail "J-b2-$sig. exit 130 on SIG$sig is unverifiable for the same reason"
        return 0
    fi

    kids="$(pids_of "$root" self)"
    grand="$(pids_of "$root" grandchild)"
    kill -"$sig" "$FX_BG_PID" 2>/dev/null || true
    if fx_wait_gone 10 "$FX_BG_PID"; then
        wait "$FX_BG_PID" 2>/dev/null
        rc=$?
    else
        kill -KILL "$FX_BG_PID" 2>/dev/null || true
    fi

    if [ "$rc" = "130" ]; then
        fx_pass "J-b1-$sig. a SIG$sig-ignoring child does not stall the runner: it exits 130 within 10s"
    else
        fx_fail "J-b1-$sig. want exit 130 within 10s of SIG$sig, got '${rc:-still running}'"
    fi

    if [ -n "$kids" ] && [ -n "$grand" ] && fx_wait_gone 10 $kids $grand; then
        fx_pass "J-b2-$sig. the SIG$sig-ignoring child and its grandchild are both KILLed"
    else
        fx_fail "J-b2-$sig. the SIG$sig-ignoring child or its grandchild survived the KILL escalation (child pids: $(echo $kids | tr '\n' ' ') grandchild pids: $(echo $grand | tr '\n' ' '))"
    fi
}

stub_case TERM
stub_case INT

# --- (c) the ordinary path pays no grace-period tax ------------------------
FAST="$(fx_new_root)"
fx_add_dummy "$FAST" f1 --lines 1
fx_add_dummy "$FAST" f2 --lines 1
fx_add_dummy "$FAST" f3 --lines 1
T0="$(fx_now_ms)"
fx_exec "$FAST" 30 "$FX_TMP_ROOT/fast.out" "$FX_TMP_ROOT/fast.err" -j 4 --all
FAST_RC=$?
T1="$(fx_now_ms)"
FAST_MS=$((T1 - T0))
FAST_EXEC="$(fx_contract_field "$FX_TMP_ROOT/fast.out" EXECUTED)"
if [ "$FAST_EXEC" = "3" ] && [ "$FAST_RC" -eq 0 ] && [ "$FAST_MS" -lt 2000 ]; then
    fx_pass "J-c. an uninterrupted run of 3 instant tests took ${FAST_MS}ms — no grace-period tax"
else
    fx_fail "J-c. want EXECUTED=3 exit 0 in under 2000ms, got EXECUTED=$FAST_EXEC exit $FAST_RC in ${FAST_MS}ms"
fi

fx_finish
