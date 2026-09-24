#!/usr/bin/env bash
# n-duration-ledger.sh — the ledger writer: segment naming, record class, sweep, concurrency.
# Tests: tests/run-all.sh, bin/lib/run-all-durations.sh, bin/lib/run-all-parallelism.sh
# Tags: tests, bin, parallel, ledger, TL2, scope:issue-specific

# WHY: one runner process owns exactly one append-only segment file, so two concurrent runners
# never share a file and correctness never rests on append atomicity. Reader cases live in n3-,
# plan-surface cases in n2-, worktree sharing in n4- (this file would exceed the size limit).

# TL3 gap (what this test does NOT catch):
# - real $HOME resolution and a real multi-core host under contention
# - a filesystem that genuinely refuses unlink (only a directory stand-in is used here)
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category pwsh-required.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

fx_init "n-duration-ledger"

DUR_LIB_REL="bin/lib/run-all-durations.sh"
DUR_LIB="$FX_REPO_ROOT/$DUR_LIB_REL"
PAR_LIB="$FX_REPO_ROOT/bin/lib/run-all-parallelism.sh"

# Every ledger row names the absent implementation instead of crashing (RED-FIRST).
dur_missing() {
    [ -f "$DUR_LIB" ] && return 1
    fx_fail "$1 (implementation missing: $DUR_LIB_REL)"
    return 0
}

HOST_TOK=""
if [ -f "$DUR_LIB" ] && [ -f "$PAR_LIB" ]; then
    # shellcheck source=/dev/null
    . "$PAR_LIB" 2>/dev/null || true
    # shellcheck source=/dev/null
    . "$DUR_LIB" 2>/dev/null || true
    HOST_TOK="$(run_all_dur_host_token 2>/dev/null || true)"
    [ -n "$HOST_TOK" ] || HOST_TOK="${RUN_ALL_DUR_HOST_TOKEN:-}"
fi

SEG_RE='^dur\.[0-9]+\.[A-Za-z0-9]{16}\.[0-9]{8}T[0-9]{6}-[0-9]{1,10}\.log$'
REC_RE='^[A-Za-z0-9]{16}\|[0-9]{1,4}\|[^|]+$'

seg_names() {
    local f
    for f in "$(fx_ledger_dir)"/dur.*; do
        [ -f "$f" ] && basename "$f"
    done 2>/dev/null
    return 0
}

# ===========================================================================
# N1/N2/N3 — one run, one segment, one record per executed test
# ===========================================================================
W="$(fx_new_root)"
fx_add_dummy "$W" a1
fx_add_dummy "$W" a2
fx_add_dummy "$W" a3
W_OUT="$FX_TMP_ROOT/w.out"; W_ERR="$FX_TMP_ROOT/w.err"

CONF="$FX_CACHE_DIR/parallelism.conf"
FX_LEDGER_KEEP=1
fx_ledger_clear
rm -f "$CONF" 2>/dev/null || true
fx_exec "$W" 90 "$W_OUT" "$W_ERR" -j 2 --all
W_EXEC="$(fx_contract_field "$W_OUT" EXECUTED)"
SEGS="$(fx_ledger_segments)"
NAMES="$(seg_names)"

if [ "$W_EXEC" = "3" ]; then
    fx_pass "N1c. the fixture is real: the run executed 3 dummies"
else
    fx_fail "N1c. the fixture is not usable — want EXECUTED=3, got ${W_EXEC:-absent}"
    fx_show_tail "$W_ERR" 6
fi

if dur_missing "N1. one run leaves exactly one correctly named segment"; then :
elif [ "$W_EXEC" = "3" ] && [ "$SEGS" = "1" ] && \
     printf '%s\n' "$NAMES" | grep -qE "$SEG_RE"; then
    fx_pass "N1. one run over 3 tests leaves exactly one segment named '$NAMES'"
else
    fx_fail "N1. want EXECUTED=3 and exactly 1 segment matching the naming class, got EXECUTED=${W_EXEC:-(absent)} segments=$SEGS name='$NAMES'"
fi

SEG_HOST="$(printf '%s\n' "$NAMES" | sed -n 's/^dur\.[0-9]*\.\([A-Za-z0-9]*\)\..*$/\1/p' | head -n 1)"
if dur_missing "N1b. the segment host token equals run_all_dur_host_token"; then :
elif [ -n "$HOST_TOK" ] && [ "$SEG_HOST" = "$HOST_TOK" ]; then
    fx_pass "N1b. segment host token is the library's own 16-char value"
else
    fx_fail "N1b. want the segment host field to equal run_all_dur_host_token='${HOST_TOK:-(unresolved)}', got '${SEG_HOST:-(absent)}'"
fi

LINES="$(fx_ledger_lines)"
GOOD="$(fx_ledger_cat | grep -cE "$REC_RE" || true)"
if dur_missing "N2. every record matches the class and there is one per executed test"; then :
elif [ "$W_EXEC" = "3" ] && [ "$LINES" = "3" ] && [ "$GOOD" = "3" ]; then
    fx_pass "N2. 3 executed tests produced exactly 3 records, all in the record class"
else
    fx_fail "N2. want 3 lines all matching the record class for EXECUTED=3, got EXECUTED=${W_EXEC:-(absent)} lines=$LINES class-matching=$GOOD"
fi

if [ -e "$CONF" ]; then
    fx_fail "N3a. the runner created $CONF; the calibrator must stay its only writer"
else
    fx_pass "N3a. a ledger-writing run does not create parallelism.conf"
fi

printf 'schema=1\njobs=3\n' > "$CONF"
cp "$CONF" "$FX_TMP_ROOT/conf.before"
fx_exec "$W" 90 "$W_OUT" "$W_ERR" -j 2 --all
if cmp -s "$CONF" "$FX_TMP_ROOT/conf.before"; then
    fx_pass "N3b. an existing parallelism.conf is byte-unchanged by a ledger-writing run"
else
    fx_fail "N3b. parallelism.conf changed during a run"
fi
rm -f "$CONF" 2>/dev/null || true

# ===========================================================================
# N7 — the sweep leaves exactly RUN_ALL_DUR_KEEP_SEGMENTS files
# ===========================================================================
KEEP="${RUN_ALL_DUR_KEEP_SEGMENTS:-16}"
PREFIX="$(printf '%s\n' "$NAMES" | sed -n 's/^\(dur\.[0-9]*\.[A-Za-z0-9]*\.\).*$/\1/p' | head -n 1)"
PLANT=$((KEEP + 3))
WANT_DROP=$((PLANT + 1 - KEEP))

old_seg() { printf '%s/%s20200101T0000%02d-1.log' "$(fx_ledger_dir)" "$PREFIX" "$1"; }

plant_old() {
    local i
    fx_ledger_clear
    mkdir -p "$(fx_ledger_dir)"
    for ((i = 1; i <= $1; i++)); do printf '' > "$(old_seg "$i")"; done
    return 0
}

if dur_missing "N7. the sweep leaves exactly $KEEP segments"; then
    fx_fail "N7b. the removed segments are the $WANT_DROP oldest by timestamp (implementation missing: $DUR_LIB_REL)"
elif [ -z "$PREFIX" ]; then
    fx_fail "N7. cannot derive a segment prefix from '$NAMES'"
else
    plant_old "$PLANT"
    fx_exec "$W" 90 "$W_OUT" "$W_ERR" -j 2 --all
    AFTER="$(fx_ledger_segments)"
    DROPPED=0
    for ((i = 1; i <= PLANT; i++)); do
        [ -e "$(old_seg "$i")" ] || DROPPED=$((DROPPED + 1))
    done
    if [ "$AFTER" = "$KEEP" ] && [ "$DROPPED" = "$WANT_DROP" ]; then
        fx_pass "N7. $PLANT planted + 1 new segment swept down to exactly $KEEP ($DROPPED removed)"
    else
        fx_fail "N7. want $KEEP surviving segments with $WANT_DROP planted ones removed, got segments=$AFTER dropped=$DROPPED"
    fi
    OLDEST_KEPT=0
    for ((i = 1; i <= WANT_DROP; i++)); do
        [ -e "$(old_seg "$i")" ] && OLDEST_KEPT=$((OLDEST_KEPT + 1))
    done
    fx_check "$OLDEST_KEPT" "N7b. the removed segments are the $WANT_DROP oldest by timestamp"
fi

# An entry the sweep cannot unlink (rm -f refuses a directory) must not stop the run.
if dur_missing "N7c. an unremovable segment keeps the run at exit 0 with one contract line"; then :
elif [ -z "$PREFIX" ]; then
    fx_fail "N7c. cannot derive a segment prefix from '$NAMES'"
else
    plant_old "$PLANT"
    mkdir -p "$(fx_ledger_dir)/${PREFIX}20200101T000000-1.log"
    fx_exec "$W" 90 "$W_OUT" "$W_ERR" -j 2 --all
    RC=$?
    NC="$(fx_count_contract "$W_OUT")"
    if [ "$RC" -eq 0 ] && [ "$NC" = "1" ]; then
        fx_pass "N7c. an unremovable segment leaves the run at exit 0 with exactly one contract line"
    else
        fx_fail "N7c. want exit 0 and one contract line, got exit $RC contract-lines=$NC"
    fi
    rm -rf "$(fx_ledger_dir)" 2>/dev/null || true
fi

# ===========================================================================
# N9 — the durations path blocked by a regular file
# ===========================================================================
fx_ledger_clear
printf 'not a directory\n' > "$(fx_ledger_dir)"
fx_exec "$W" 90 "$W_OUT" "$W_ERR" -j 2 --all
RC=$?
NC="$(fx_count_contract "$W_OUT")"
STRAY="$(grep -vc '^\[run-all\] ' "$W_ERR" 2>/dev/null || true)"
[ -n "$STRAY" ] || STRAY=0
if [ "$RC" -eq 0 ] && [ "$NC" = "1" ] && [ "$STRAY" = "0" ]; then
    fx_pass "N9. a regular file blocking durations/ leaves exit 0, one contract line and no extra stderr"
else
    fx_fail "N9. want exit 0, one contract line and only '[run-all] ' stderr, got exit $RC contract-lines=$NC stray-stderr-lines=$STRAY"
    fx_show_tail "$W_ERR" 6
fi
rm -f "$(fx_ledger_dir)" 2>/dev/null || true

# ===========================================================================
# N10 — two runners against one cache directory
# ===========================================================================
fx_ledger_clear
C_OUT1="$FX_TMP_ROOT/c1.out"; C_ERR1="$FX_TMP_ROOT/c1.err"
C_OUT2="$FX_TMP_ROOT/c2.out"; C_ERR2="$FX_TMP_ROOT/c2.err"
fx_exec_bg "$W" "$C_OUT1" "$C_ERR1" -j 2 --all
PID1="$FX_BG_PID"
fx_exec_bg "$W" "$C_OUT2" "$C_ERR2" -j 2 --all
PID2="$FX_BG_PID"
wait "$PID1" 2>/dev/null
wait "$PID2" 2>/dev/null

C_SEGS="$(fx_ledger_segments)"
C_LINES="$(fx_ledger_lines)"
C_CLASS="$(fx_ledger_cat | grep -cE "$REC_RE" || true)"
C_DISTINCT="$(seg_names | LC_ALL=C sort -u | grep -c . || true)"
# Exactly two writers x three tests: any key seen a number of times other than 2 means a
# record was lost or duplicated, which a class-only assertion would report as healthy.
C_BADKEYS="$(fx_ledger_cat | awk -F'|' 'NF == 3 { n[$3]++ } END { c = 0; for (k in n) if (n[k] != 2) c++; print c + 0 }')"
C_KEYS="$(fx_ledger_cat | awk -F'|' 'NF == 3 { n[$3] = 1 } END { c = 0; for (k in n) c++; print c + 0 }')"

if dur_missing "N10. two concurrent runners write two disjoint segments"; then :
elif [ "$C_SEGS" = "2" ] && [ "$C_DISTINCT" = "2" ] && [ "$C_LINES" = "6" ] && \
     [ "$C_CLASS" = "6" ] && [ "$C_KEYS" = "3" ] && [ "$C_BADKEYS" = "0" ]; then
    fx_pass "N10. two runners left 2 distinct segments, 6 records, 3 keys, each key exactly twice"
else
    fx_fail "N10. want segments=2 distinct=2 lines=6 class=6 keys=3 bad-key-counts=0, got segments=$C_SEGS distinct=$C_DISTINCT lines=$C_LINES class=$C_CLASS keys=$C_KEYS bad-key-counts=$C_BADKEYS"
fi

# ===========================================================================
# N15 — a test path containing a space
# ===========================================================================
SP="$(fx_new_root)"
fx_add_dummy "$SP" s0 --sleep 2
{
    printf '#!/usr/bin/env bash\n'
    printf '# Tests: tests/run-all.sh\n'
    printf '# Tags: fixture, parallel, scope:issue-specific\n'
    printf 'sleep 2\n'
    printf 'exit 0\n'
} > "$SP/tests/with space.sh"
chmod +x "$SP/tests/with space.sh" 2>/dev/null || true

SP_OUT="$FX_TMP_ROOT/sp.out"; SP_ERR="$FX_TMP_ROOT/sp.err"
fx_ledger_clear
fx_exec "$SP" 90 "$SP_OUT" "$SP_ERR" -j 2 --all
SP_EXEC="$(fx_contract_field "$SP_OUT" EXECUTED)"
SP_KEY="$(fx_ledger_cat | awk -F'|' 'NF == 3 && $3 ~ /with space\.sh$/ { print $3 }' | head -n 1)"

if dur_missing "N15. a path with a space is keyed verbatim"; then :
elif [ "$SP_EXEC" = "2" ] && [ -n "$SP_KEY" ]; then
    fx_pass "N15. the spaced test produced a record keyed '$SP_KEY' (space preserved)"
else
    fx_fail "N15. want EXECUTED=2 and a record whose key ends in 'with space.sh', got EXECUTED=${SP_EXEC:-(absent)} key='${SP_KEY:-(none)}'"
fi

fx_exec "$SP" 60 "$SP_OUT" "$SP_ERR" --print-plan --all
SP_TIER="$(awk -F'\t' '$1 == "plan" && $4 ~ /with space\.sh$/ { print $5 }' "$SP_OUT" | head -n 1)"
UNMEASURED="${RUN_ALL_DUR_TIER_UNMEASURED:-99}"
if dur_missing "N15b. the spaced test is looked up as measured on the next run"; then :
elif [ -n "$SP_TIER" ] && [ "$SP_TIER" != "$UNMEASURED" ]; then
    fx_pass "N15b. the spaced test reports a measured tier ($SP_TIER), so its key round-tripped"
else
    fx_fail "N15b. want a plan tier other than $UNMEASURED for the spaced test, got '${SP_TIER:-(absent)}'"
fi
FX_LEDGER_KEEP=0

fx_finish
